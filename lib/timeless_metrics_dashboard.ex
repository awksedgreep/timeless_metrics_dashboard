defmodule TimelessMetricsDashboard do
  @moduledoc """
  Telemetry reporter and LiveDashboard page for TimelessMetrics.

  Captures `Telemetry.Metrics` events into a Timeless store, giving you
  persistent historical metrics that survive restarts — unlike the built-in
  LiveDashboard charts which reset on every page load.

  ## Reporter (standalone — no Phoenix required)

      children = [
        {Timeless, name: :metrics, data_dir: "/var/lib/metrics"},
        {TimelessMetricsDashboard,
          store: :metrics,
          metrics:
            TimelessMetricsDashboard.DefaultMetrics.vm_metrics() ++
            TimelessMetricsDashboard.DefaultMetrics.phoenix_metrics()}
      ]

  ## LiveDashboard Page

      # In your router:
      live_dashboard "/dashboard",
        additional_pages: [timeless: {TimelessMetricsDashboard.Page, store: :metrics}]
  """

  @doc """
  Returns a child spec that starts the TimelessMetrics store + telemetry reporter.

  ## Options

    * `:name` — store name (default: `:timeless_metrics`)
    * `:data_dir` — data directory (default: `"priv/timeless_metrics"`)
    * `:metrics` — `Telemetry.Metrics` list (default: `DefaultMetrics.all()`)
    * `:reporter` — extra opts forwarded to Reporter (`:flush_interval`, `:prefix`)
  """
  def child_spec(opts) do
    name = Keyword.get(opts, :name, :timeless_metrics)

    %{
      id: {__MODULE__, name},
      start: {TimelessMetricsDashboard.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Callback for LiveDashboard's `metrics_history` option.

  Queries the Timeless store for recent data points matching the given
  `Telemetry.Metrics` struct and returns them in the format LiveDashboard
  expects.

  ## Router Configuration

      live_dashboard "/dashboard",
        metrics: MyAppWeb.Telemetry,
        metrics_history: {TimelessMetricsDashboard, :metrics_history, [:my_store]}

  The store atom is appended by your MFA config; LiveDashboard prepends
  the metric struct, so the call becomes:

      TimelessMetricsDashboard.metrics_history(metric, :my_store)

  ## Options

  A keyword list can be passed as a third element for additional config:

      metrics_history: {TimelessMetricsDashboard, :metrics_history, [:my_store, [prefix: "app"]]}

  Supported options:

    * `:prefix` — metric name prefix (default: `"telemetry"`, must match your Reporter prefix)
    * `:history` — seconds of history to return (default: `3600`)
  """
  @spec metrics_history(Telemetry.Metrics.t(), atom(), keyword()) :: [map()]
  def metrics_history(metric, store, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "telemetry")
    history = Keyword.get(opts, :history, 3600)

    metric_name = build_metric_name(prefix, metric)
    from = System.os_time(:second) - history
    to = System.os_time(:second)

    # Query all label combinations for this metric
    case TimelessMetrics.query_multi(store, metric_name, %{}, from: from, to: to) do
      {:ok, series_list} ->
        series_list
        |> Enum.flat_map(fn %{labels: labels, points: points} ->
          label = build_label(metric, labels)
          Enum.map(points, fn {timestamp, value} -> {label, timestamp, value} end)
        end)
        # Group by label, then average overlapping timestamps within each group.
        # Multiple Timeless series can collapse to the same label when the
        # LiveDashboard metric has fewer tags than the reporter stored.
        |> Enum.group_by(&elem(&1, 0))
        |> Enum.flat_map(fn {label, points} ->
          points
          |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {timestamp, values} ->
            %{
              label: label,
              measurement: Enum.sum(values) / length(values),
              time: timestamp * 1_000_000
            }
          end)
        end)

      _ ->
        []
    end
  end

  # Match the reporter's naming convention
  defp build_metric_name(prefix, metric) do
    name_parts = Enum.map(metric.name, &to_string/1)
    "#{prefix}.#{Enum.join(name_parts, ".")}"
  end

  # Reconstruct the label string from Timeless labels + metric tags
  defp build_label(%{tags: []}, _labels), do: nil
  defp build_label(%{tags: nil}, _labels), do: nil

  defp build_label(%{tags: tags}, labels) do
    label =
      tags
      |> Enum.map(fn tag -> Map.get(labels, to_string(tag), "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    if label == "", do: nil, else: label
  end
end
