defmodule TimelessMetricsDashboard.Reporter do
  @moduledoc """
  Telemetry reporter that writes `Telemetry.Metrics` events into a Timeless store.

  The handler callback runs in the **caller's process**, so all hot-path
  operations are lock-free ETS reads/writes. A periodic flush drains the
  buffer into Timeless via `write_batch_resolved/2`.

  ## Options

    * `:store` (required) — Timeless store name (atom)
    * `:metrics` — list of `Telemetry.Metrics` structs (default: `[]`)
    * `:flush_interval` — milliseconds between batch flushes (default: `10_000`)
    * `:prefix` — metric name prefix (default: `"telemetry"`)
    * `:name` — GenServer name (default: `TimelessMetricsDashboard.Reporter`)
  """

  use GenServer

  require Logger

  @default_flush_interval 10_000
  @default_prefix "telemetry"

  # --- Child spec / start ---

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

  # --- Public API ---

  @doc "Synchronous flush — drains the buffer immediately. Useful for testing."
  def flush(name \\ __MODULE__) do
    GenServer.call(name, :flush, :infinity)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    store = Keyword.fetch!(opts, :store)
    metrics = Keyword.get(opts, :metrics, [])
    flush_interval = Keyword.get(opts, :flush_interval, @default_flush_interval)
    prefix = Keyword.get(opts, :prefix, @default_prefix)

    # ETS tables for lock-free handler path
    cache = :ets.new(:timeless_reporter_cache, [:set, :public, read_concurrency: true])
    buffer = :ets.new(:timeless_reporter_buffer, [:set, :public, write_concurrency: true])

    # Group metrics by event name → attach one handler per distinct event
    handler_ids =
      metrics
      |> Enum.group_by(& &1.event_name)
      |> Enum.map(fn {event_name, event_metrics} ->
        handler_id = handler_id(prefix, event_name)

        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_event/4,
          %{
            metrics: event_metrics,
            store: store,
            prefix: prefix,
            cache: cache,
            buffer: buffer
          }
        )

        handler_id
      end)

    # Register metric metadata in Timeless
    register_metrics(store, metrics, prefix)

    # Schedule periodic flush
    if flush_interval > 0 do
      Process.send_after(self(), :flush, flush_interval)
    end

    {:ok,
     %{
       store: store,
       metrics: metrics,
       prefix: prefix,
       flush_interval: flush_interval,
       handler_ids: handler_ids,
       cache: cache,
       buffer: buffer
     }}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    drain_buffer(state)
    {:reply, :ok, state}
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

  # --- Telemetry handler (runs in caller's process) ---

  @doc false
  def handle_event(_event_name, measurements, metadata, config) do
    %{metrics: metrics, store: store, prefix: prefix, cache: cache, buffer: buffer} = config

    Enum.each(metrics, fn metric ->
      if keep?(metric, metadata) do
        case extract_value(metric, measurements, metadata) do
          nil ->
            :skip

          value ->
            value = convert_unit(value, metric.unit)
            labels = extract_labels(metric, metadata)
            metric_name = build_metric_name(prefix, metric)
            series_id = resolve_cached(cache, store, metric_name, labels)
            timestamp = System.os_time(:second)
            key = {series_id, :erlang.unique_integer()}
            :ets.insert(buffer, {key, {timestamp, value}})
        end
      end
    end)
  end

  # --- Internals ---

  defp handler_id(prefix, event_name) do
    {__MODULE__, prefix, event_name}
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(%{keep: keep}, metadata) when is_function(keep, 1), do: keep.(metadata)
  defp keep?(_metric, _metadata), do: true

  defp extract_value(metric, measurements, metadata) do
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
      {to_string(tag), to_string(Map.get(tag_values, tag, ""))}
    end)
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Map.new()
  end

  defp build_metric_name(prefix, metric) do
    name_parts = Enum.map(metric.name, &to_string/1)
    "#{prefix}.#{Enum.join(name_parts, ".")}"
  end

  defp resolve_cached(cache, store, metric_name, labels) do
    key = {metric_name, labels}

    case :ets.lookup(cache, key) do
      [{^key, series_id}] ->
        series_id

      [] ->
        series_id = TimelessMetrics.resolve_series(store, metric_name, labels)
        :ets.insert(cache, {key, series_id})
        series_id
    end
  end

  defp drain_buffer(state) do
    entries = :ets.tab2list(state.buffer)
    :ets.delete_all_objects(state.buffer)

    if entries != [] do
      batch =
        Enum.map(entries, fn {{series_id, _unique}, {timestamp, value}} ->
          {series_id, value, timestamp}
        end)

      TimelessMetrics.write_batch_resolved(state.store, batch)
    end
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

  defp register_metrics(store, metrics, prefix) do
    Enum.each(metrics, fn metric ->
      metric_name = build_metric_name(prefix, metric)
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
end
