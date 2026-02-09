defmodule TimelessDashboard.DefaultMetrics do
  @moduledoc """
  Pre-built `Telemetry.Metrics` definitions for common BEAM/Phoenix/Ecto/Timeless events.

  These return standard `Telemetry.Metrics` structs — you can mix them with
  your own custom metrics when configuring the reporter.

  ## Example

      metrics =
        TimelessDashboard.DefaultMetrics.vm_metrics() ++
        TimelessDashboard.DefaultMetrics.phoenix_metrics() ++
        TimelessDashboard.DefaultMetrics.ecto_metrics("my_app.repo") ++
        TimelessDashboard.DefaultMetrics.timeless_metrics()

      {TimelessDashboard, store: :metrics, metrics: metrics}
  """

  import Telemetry.Metrics

  @doc """
  VM metrics emitted by `:telemetry_poller`.

  Requires `{:telemetry_poller, "~> 1.0"}` in your deps and the default
  poller running (it starts automatically).

  Captures memory (total, processes, binary, atom, ets), run queue lengths,
  and system counts (processes, atoms, ports).
  """
  def vm_metrics do
    [
      # Memory
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes_used", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.atom", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),

      # Run queues
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # System counts
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.atom_count"),
      last_value("vm.system_counts.port_count")
    ]
  end

  @doc """
  Phoenix endpoint, router, channel, and socket metrics.

  Captures request duration and count, tagged by method, route, and status.
  Channel metrics are tagged by channel module and transport.
  """
  def phoenix_metrics do
    [
      # Endpoint
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :status],
        tag_values: &phoenix_tag_values/1
      ),
      counter("phoenix.endpoint.stop.duration",
        tags: [:method, :status],
        tag_values: &phoenix_tag_values/1
      ),

      # Router dispatch
      summary("phoenix.router_dispatch.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :route, :status],
        tag_values: &phoenix_router_tag_values/1
      ),
      counter("phoenix.router_dispatch.stop.duration",
        tags: [:method, :route, :status],
        tag_values: &phoenix_router_tag_values/1
      ),

      # Channel joined
      summary("phoenix.channel_joined.stop.duration",
        unit: {:native, :millisecond},
        tags: [:channel, :transport],
        tag_values: &channel_joined_tag_values/1
      ),
      counter("phoenix.channel_joined.stop.duration",
        tags: [:channel, :transport],
        tag_values: &channel_joined_tag_values/1
      ),

      # Channel handled_in
      summary("phoenix.channel_handled_in.stop.duration",
        unit: {:native, :millisecond},
        tags: [:channel, :event],
        tag_values: &channel_handled_in_tag_values/1
      ),

      # Socket connected
      summary("phoenix.socket_connected.stop.duration",
        unit: {:native, :millisecond}
      )
    ]
  end

  @doc """
  Ecto repo metrics.

  Takes the repo event prefix as a string (e.g., `"my_app.repo"`).
  Captures query total_time, queue_time, decode_time, and idle_time,
  tagged by source table.
  """
  def ecto_metrics(repo_prefix) do
    event_prefix =
      repo_prefix
      |> String.split(".")
      |> Enum.map(&String.to_atom/1)

    [
      summary(event_prefix ++ [:query, :total_time],
        unit: {:native, :millisecond},
        tags: [:source],
        tag_values: &ecto_tag_values/1
      ),
      counter(event_prefix ++ [:query, :total_time],
        tags: [:source],
        tag_values: &ecto_tag_values/1
      ),
      summary(event_prefix ++ [:query, :queue_time],
        unit: {:native, :millisecond},
        tags: [:source],
        tag_values: &ecto_tag_values/1
      ),
      summary(event_prefix ++ [:query, :decode_time],
        unit: {:native, :millisecond},
        tags: [:source],
        tag_values: &ecto_tag_values/1
      ),
      summary(event_prefix ++ [:query, :idle_time],
        unit: {:native, :millisecond},
        tags: [:source],
        tag_values: &ecto_tag_values/1
      )
    ]
  end

  @doc """
  Phoenix LiveView and LiveComponent metrics.

  Captures mount, handle_event, and handle_params durations for LiveViews,
  plus handle_event for LiveComponents.
  """
  def live_view_metrics do
    [
      # LiveView mount
      summary("phoenix.live_view.mount.stop.duration",
        unit: {:native, :millisecond},
        tags: [:view],
        tag_values: &live_view_mount_tag_values/1
      ),

      # LiveView handle_event
      summary("phoenix.live_view.handle_event.stop.duration",
        unit: {:native, :millisecond},
        tags: [:view, :event],
        tag_values: &live_view_event_tag_values/1
      ),

      # LiveView handle_params (live navigation)
      summary("phoenix.live_view.handle_params.stop.duration",
        unit: {:native, :millisecond},
        tags: [:view],
        tag_values: &live_view_mount_tag_values/1
      ),

      # LiveComponent handle_event
      summary("phoenix.live_component.handle_event.stop.duration",
        unit: {:native, :millisecond},
        tags: [:component, :event],
        tag_values: &live_component_event_tag_values/1
      )
    ]
  end

  @doc """
  Timeless internal metrics.

  Captures the TSDB's own performance: buffer flushes, segment compression,
  query latency, rollup duration, HTTP import throughput, and backpressure events.

  These let you monitor Timeless itself — the database tracking its own health.
  """
  def timeless_metrics do
    [
      # Buffer flush — points and series flushed per cycle
      summary("timeless.buffer.flush.point_count"),
      summary("timeless.buffer.flush.series_count"),

      # Segment write — compression efficiency
      summary("timeless.segment.write.point_count"),
      summary("timeless.segment.write.compressed_bytes", unit: :byte),

      # Query performance
      summary("timeless.query.raw.duration_us", unit: {:microsecond, :millisecond}),
      summary("timeless.query.raw.point_count"),
      summary("timeless.query.raw.segment_count"),

      # Rollup duration by tier
      summary("timeless.rollup.complete.duration_us",
        unit: {:microsecond, :millisecond},
        tags: [:tier],
        tag_values: &timeless_tier_tag_values/1
      ),
      summary("timeless.rollup.late_catch_up.duration_us",
        unit: {:microsecond, :millisecond},
        tags: [:tier],
        tag_values: &timeless_tier_tag_values/1
      ),

      # HTTP import throughput
      summary("timeless.http.import.sample_count"),
      counter("timeless.http.import.sample_count"),
      summary("timeless.http.import.error_count"),

      # Backpressure — early warning
      counter("timeless.write.backpressure.count",
        tags: [:shard],
        tag_values: &timeless_shard_tag_values/1
      )
    ]
  end

  # --- Tag value extractors ---

  defp phoenix_tag_values(%{conn: conn}) do
    %{
      method: conn.method,
      status: conn.status
    }
  end

  defp phoenix_tag_values(metadata), do: metadata

  defp phoenix_router_tag_values(%{conn: conn, route: route}) do
    %{
      method: conn.method,
      route: route,
      status: conn.status
    }
  end

  defp phoenix_router_tag_values(%{conn: conn}) do
    %{
      method: conn.method,
      route: conn.request_path,
      status: conn.status
    }
  end

  defp phoenix_router_tag_values(metadata), do: metadata

  defp channel_joined_tag_values(%{socket: socket}) do
    %{
      channel: inspect(socket.channel),
      transport: to_string(socket.transport)
    }
  end

  defp channel_joined_tag_values(metadata), do: metadata

  defp channel_handled_in_tag_values(%{socket: socket, event: event}) do
    %{
      channel: inspect(socket.channel),
      event: event
    }
  end

  defp channel_handled_in_tag_values(metadata), do: metadata

  defp ecto_tag_values(%{source: source}) when is_binary(source), do: %{source: source}
  defp ecto_tag_values(_metadata), do: %{source: "unknown"}

  defp live_view_mount_tag_values(%{socket: socket}) do
    %{view: inspect(socket.view)}
  end

  defp live_view_mount_tag_values(metadata), do: metadata

  defp live_view_event_tag_values(%{socket: socket, event: event}) do
    %{view: inspect(socket.view), event: event}
  end

  defp live_view_event_tag_values(metadata), do: metadata

  defp live_component_event_tag_values(%{socket: socket, event: event}) do
    %{component: inspect(socket.assigns.__component__), event: event}
  rescue
    _ -> %{component: "unknown", event: event}
  end

  defp live_component_event_tag_values(metadata), do: metadata

  defp timeless_tier_tag_values(%{tier: tier}), do: %{tier: to_string(tier)}
  defp timeless_tier_tag_values(metadata), do: metadata

  defp timeless_shard_tag_values(%{shard: shard}), do: %{shard: to_string(shard)}
  defp timeless_shard_tag_values(metadata), do: metadata
end
