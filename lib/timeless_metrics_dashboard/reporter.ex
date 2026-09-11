defmodule TimelessMetricsDashboard.Reporter do
  @moduledoc """
  Telemetry reporter that writes `Telemetry.Metrics` events into a Timeless store.

  The handler callback runs in the **caller's process**, so the hot path is a
  bounded ETS insert. A periodic flush drains accepted entries into Timeless in
  chunks. Entries are deleted only after a successful write, so concurrent
  inserts and transient store failures do not lose queued points.

  ## Options

    * `:store` (required) — Timeless store name (atom)
    * `:metrics` — list of `Telemetry.Metrics` structs (default: `[]`)
    * `:flush_interval` — milliseconds between batch flushes (default: `10_000`)
    * `:prefix` — metric name prefix (default: `"telemetry"`)
    * `:name` — GenServer name (default: `TimelessMetricsDashboard.Reporter`)
    * `:max_buffer_size` — maximum queued points; newer points are dropped once
      full (default: `100_000`)
    * `:batch_size` — maximum points written per store call (default: `5_000`)
  """

  use GenServer

  require Logger

  @default_flush_interval 10_000
  @default_prefix "telemetry"
  @default_max_buffer_size 100_000
  @default_batch_size 5_000

  @buffered_counter 1
  @dropped_counter 2
  @write_error_counter 3
  @callback_error_counter 4

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Synchronous flush — drains the buffer immediately. Useful for testing."
  def flush(name \\ __MODULE__) do
    GenServer.call(name, :flush, :infinity)
  end

  @doc "Returns reporter buffer, drop, write-error, and callback-error counters."
  def stats(name \\ __MODULE__) do
    GenServer.call(name, :stats)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    store = Keyword.fetch!(opts, :store)
    reporter_name = Keyword.get(opts, :name, __MODULE__)
    prefix = Keyword.get(opts, :prefix, @default_prefix)
    flush_interval = Keyword.get(opts, :flush_interval, @default_flush_interval)
    max_buffer_size = positive_option!(opts, :max_buffer_size, @default_max_buffer_size)
    batch_size = positive_option!(opts, :batch_size, @default_batch_size)
    counters = :atomics.new(4, signed: false)
    metrics = opts |> Keyword.get(:metrics, []) |> prepare_metrics(prefix)

    register_metrics(store, metrics)

    buffer = :ets.new(:timeless_reporter_buffer, [:set, :public, write_concurrency: true])

    handler_ids =
      metrics
      |> Enum.group_by(& &1.metric.event_name)
      |> Enum.map(fn {event_name, event_metrics} ->
        handler_id = handler_id(reporter_name, prefix, event_name)

        # terminate/2 is skipped for abrupt exits. Always detach an old handler
        # before attaching so telemetry callers cannot retain a dead table TID.
        :telemetry.detach(handler_id)

        :ok =
          :telemetry.attach(
            handler_id,
            event_name,
            &__MODULE__.handle_event/4,
            %{
              metrics: event_metrics,
              buffer: buffer,
              counters: counters,
              max_buffer_size: max_buffer_size
            }
          )

        handler_id
      end)

    if flush_interval > 0 do
      Process.send_after(self(), :flush, flush_interval)
    end

    {:ok,
     %{
       store: store,
       metrics: metrics,
       prefix: prefix,
       flush_interval: flush_interval,
       max_buffer_size: max_buffer_size,
       batch_size: batch_size,
       handler_ids: handler_ids,
       buffer: buffer,
       counters: counters
     }}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    drain_buffer(state)
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      buffered: :atomics.get(state.counters, @buffered_counter),
      dropped: :atomics.get(state.counters, @dropped_counter),
      write_errors: :atomics.get(state.counters, @write_error_counter),
      callback_errors: :atomics.get(state.counters, @callback_error_counter)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush, state) do
    drain_buffer(state)

    if state.flush_interval > 0 do
      Process.send_after(self(), :flush, state.flush_interval)
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handler_ids, &:telemetry.detach/1)
    drain_buffer(state)
    :ok
  end

  @doc false
  def handle_event(_event_name, measurements, metadata, config) do
    timestamp = System.os_time(:second)
    event_id = :erlang.unique_integer()

    Enum.each(config.metrics, fn prepared ->
      capture_metric(prepared, measurements, metadata, timestamp, event_id, config)
    end)
  end

  defp handler_id(reporter_name, prefix, event_name) do
    {__MODULE__, reporter_name, prefix, event_name}
  end

  defp capture_metric(
         %{metric: metric, name: metric_name},
         measurements,
         metadata,
         timestamp,
         event_id,
         config
       ) do
    try do
      if keep?(metric, metadata) do
        case extract_value(metric, measurements, metadata) do
          nil ->
            :skip

          value ->
            value = convert_unit(value, metric.unit)
            labels = extract_labels(metric, metadata)
            insert_point(config, metric_name, labels, timestamp, value, event_id)
        end
      end
    rescue
      _ -> :atomics.add(config.counters, @callback_error_counter, 1)
    catch
      _, _ -> :atomics.add(config.counters, @callback_error_counter, 1)
    end
  end

  defp insert_point(config, metric_name, labels, timestamp, value, event_id) do
    buffered = :atomics.add_get(config.counters, @buffered_counter, 1)

    if buffered <= config.max_buffer_size do
      key = {metric_name, event_id}

      try do
        true = :ets.insert(config.buffer, {key, {labels, timestamp, value}})
      rescue
        # There is a small interval between an abrupt Reporter exit and stale
        # handler detachment. Never propagate the dead-TID error to the emitter.
        ArgumentError ->
          :atomics.sub(config.counters, @buffered_counter, 1)
          :atomics.add(config.counters, @dropped_counter, 1)
      end
    else
      :atomics.sub(config.counters, @buffered_counter, 1)
      :atomics.add(config.counters, @dropped_counter, 1)
    end
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(%{keep: keep}, metadata) when is_function(keep, 1), do: keep.(metadata)
  defp keep?(_metric, _metadata), do: true

  defp extract_value(%Telemetry.Metrics.Counter{} = metric, measurements, metadata) do
    case extract_measurement(metric, measurements, metadata) do
      nil -> nil
      _measurement -> 1
    end
  end

  defp extract_value(metric, measurements, metadata) do
    extract_measurement(metric, measurements, metadata)
  end

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key when is_atom(key) -> Map.get(measurements, key)
    end
  end

  defp extract_labels(metric, metadata) do
    tag_values =
      case metric.tag_values do
        fun when is_function(fun, 1) -> fun.(metadata)
        _ -> metadata
      end

    metric.tags
    |> Enum.map(fn tag ->
      {to_string(tag), tag_values |> Map.get(tag, "") |> bounded_string()}
    end)
    |> Enum.reject(fn {_key, value} -> value == "" end)
    |> Map.new()
  end

  defp bounded_string(value) do
    value
    |> to_string()
    |> String.slice(0, 200)
  end

  defp build_metric_name(prefix, metric) do
    name_parts = Enum.map(metric.name, &to_string/1)
    "#{prefix}.#{Enum.join(name_parts, ".")}"
  end

  defp drain_buffer(state) do
    state.buffer
    |> :ets.tab2list()
    |> Enum.chunk_every(state.batch_size)
    |> Enum.reduce_while(:ok, fn entries, :ok ->
      batch =
        Enum.map(entries, fn {{metric_name, _unique}, {labels, timestamp, value}} ->
          {metric_name, labels, value, timestamp}
        end)

      case write_batch(state.store, batch) do
        :ok ->
          # Keys are unique and never overwritten. Delete only the accepted
          # snapshot; points inserted concurrently stay queued.
          deleted =
            Enum.count(entries, fn {key, _value} ->
              :ets.take(state.buffer, key) != []
            end)

          :atomics.sub(state.counters, @buffered_counter, deleted)
          {:cont, :ok}

        {:error, reason} ->
          :atomics.add(state.counters, @write_error_counter, 1)
          Logger.error("TimelessMetricsDashboard.Reporter flush failed: #{inspect(reason)}")
          {:halt, :error}
      end
    end)
  end

  defp write_batch(store, batch) do
    case TimelessMetrics.write_batch(store, batch) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp convert_unit(value, unit) do
    case unit do
      {:native, :millisecond} ->
        System.convert_time_unit(trunc(value), :native, :millisecond) / 1

      {:native, :microsecond} ->
        System.convert_time_unit(trunc(value), :native, :microsecond) / 1

      {:native, :second} ->
        System.convert_time_unit(trunc(value), :native, :second) / 1

      {:byte, :kilobyte} ->
        value / 1024

      {:byte, :megabyte} ->
        value / (1024 * 1024)

      {:byte, :gigabyte} ->
        value / (1024 * 1024 * 1024)

      {:microsecond, :millisecond} ->
        value / 1000

      _ ->
        value
    end
  end

  defp register_metrics(store, metrics) do
    Enum.each(metrics, fn %{metric: metric, name: metric_name} ->
      type = metric_type(metric)
      unit = format_unit(metric.unit)
      description = Map.get(metric, :description)

      TimelessMetrics.register_metric(store, metric_name, type,
        unit: unit,
        description: description
      )
    end)
  end

  defp metric_type(%Telemetry.Metrics.Counter{}), do: :counter
  defp metric_type(%Telemetry.Metrics.Sum{}), do: :counter
  defp metric_type(%Telemetry.Metrics.LastValue{}), do: :gauge
  defp metric_type(%Telemetry.Metrics.Summary{}), do: :gauge
  defp metric_type(%Telemetry.Metrics.Distribution{}), do: :histogram

  defp format_unit({_, to}), do: to_string(to)
  defp format_unit(unit) when is_atom(unit), do: to_string(unit)
  defp format_unit(_), do: nil

  defp prepare_metrics(metrics, prefix) do
    metrics
    |> Enum.map(&%{metric: &1, name: build_metric_name(prefix, &1)})
    |> Enum.reduce({MapSet.new(), []}, fn prepared, {seen, acc} ->
      if MapSet.member?(seen, prepared.name) do
        Logger.warning("Ignoring duplicate telemetry metric name #{inspect(prepared.name)}")
        {seen, acc}
      else
        {MapSet.put(seen, prepared.name), [prepared | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
