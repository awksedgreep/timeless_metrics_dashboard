# TimelessMetricsDashboard

Telemetry reporter and [LiveDashboard](https://github.com/phoenixframework/phoenix_live_dashboard) page plugin for [Timeless](https://github.com/awksedgreep/timeless).

Phoenix LiveDashboard ships real-time metrics that reset on every page load. TimelessMetricsDashboard bridges the gap: a telemetry reporter captures events into Timeless, and the dashboard page gives you persistent historical charts, alert visibility, backup controls, and compression stats.

Drop it in and your LiveDashboard gets real trending for free.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:timeless, github: "awksedgreep/timeless"},
    {:timeless_metrics_dashboard, github: "awksedgreep/timeless_metrics_dashboard"}
  ]
end
```

## Setup

### 1. Reporter (standalone -- no Phoenix required)

Add the reporter to your supervision tree. It captures `Telemetry.Metrics` events and writes them into a Timeless store.

```elixir
# application.ex
children = [
  {Timeless, name: :metrics, data_dir: "/var/lib/metrics"},
  {TimelessMetricsDashboard,
    store: :metrics,
    metrics:
      TimelessMetricsDashboard.DefaultMetrics.vm_metrics() ++
      TimelessMetricsDashboard.DefaultMetrics.phoenix_metrics() ++
      TimelessMetricsDashboard.DefaultMetrics.ecto_metrics("my_app.repo") ++
      TimelessMetricsDashboard.DefaultMetrics.live_view_metrics()}
]
```

The reporter works without Phoenix. Any application that uses `:telemetry` can use it.

### 2. LiveDashboard Page

Add the page to your router:

```elixir
# router.ex
live_dashboard "/dashboard",
  additional_pages: [
    timeless: {TimelessMetricsDashboard.Page, store: :metrics}
  ]
```

### 3. Backup Downloads (optional)

To enable download links on the Storage tab, mount the download plug and pass the path:

```elixir
# router.ex
forward "/timeless/downloads", TimelessMetricsDashboard.DownloadPlug, store: :metrics

live_dashboard "/dashboard",
  additional_pages: [
    timeless: {TimelessMetricsDashboard.Page,
      store: :metrics,
      download_path: "/timeless/downloads"}
  ]
```

## Dashboard Tabs

### Overview

Store statistics at a glance: series count, total points, compression ratio, storage size, and rollup tier breakdown.

### Metrics

Browse all metrics in the store (both telemetry-captured and directly written), select a time range, and view SVG charts with automatic bucketing. Metric metadata (type, unit, description) is displayed when available.

All metrics written to the Timeless store appear here, whether they came through the reporter or were written directly via `Timeless.write/4`.

### Alerts

Lists all configured alert rules with their current state (ok/pending/firing). Includes inline documentation with examples for creating alerts via the Timeless API:

```elixir
Timeless.create_alert(:metrics,
  name: "high_memory",
  metric: "telemetry.vm.memory.total",
  condition: :above,
  threshold: 512_000_000,
  duration: 60
)

# With webhook notification (ntfy.sh, Slack, etc.)
Timeless.create_alert(:metrics,
  name: "high_latency",
  metric: "telemetry.phoenix.endpoint.stop.duration",
  condition: :above,
  threshold: 500,
  duration: 120,
  aggregate: :avg,
  webhook_url: "https://ntfy.sh/my-alerts"
)
```

### Storage

Database path, size, and retention settings. Create and download backups, flush buffered data to disk.

## Reporter Options

| Option | Default | Description |
|--------|---------|-------------|
| `:store` | *required* | Timeless store name (atom) |
| `:metrics` | `[]` | List of `Telemetry.Metrics` structs |
| `:flush_interval` | `10_000` | Milliseconds between batch flushes |
| `:prefix` | `"telemetry"` | Metric name prefix |
| `:name` | `TimelessMetricsDashboard.Reporter` | GenServer name |

## Page Options

| Option | Default | Description |
|--------|---------|-------------|
| `:store` | *required* | Timeless store name (atom) |
| `:chart_width` | `700` | SVG chart width in pixels |
| `:chart_height` | `250` | SVG chart height in pixels |
| `:download_path` | `nil` | Path to DownloadPlug (enables download links) |

## Default Metrics

Pre-built metric definitions for common events:

- **`TimelessMetricsDashboard.DefaultMetrics.vm_metrics/0`** -- Memory, run queues, system counts. Requires `:telemetry_poller`.
- **`TimelessMetricsDashboard.DefaultMetrics.phoenix_metrics/0`** -- Endpoint and router dispatch duration/count, tagged by method/route/status.
- **`TimelessMetricsDashboard.DefaultMetrics.ecto_metrics/1`** -- Query total_time and queue_time, tagged by source table. Pass the repo event prefix (e.g., `"my_app.repo"`).
- **`TimelessMetricsDashboard.DefaultMetrics.live_view_metrics/0`** -- Mount and handle_event duration, tagged by view/event.

Mix and match with your own custom `Telemetry.Metrics` definitions.

## Architecture

The reporter handler runs in the **caller's process**, not the GenServer. All hot-path operations are lock-free:

- **Cache ETS** (`read_concurrency: true`) -- Maps `{metric_name, labels}` to `series_id`. First miss calls `Timeless.resolve_series/3`, then all subsequent lookups are O(1).
- **Buffer ETS** (`write_concurrency: true`) -- Accumulates `{series_id, timestamp, value}` from concurrent handlers.
- **Periodic flush** -- GenServer drains the buffer and calls `Timeless.write_batch_resolved/2`.

## Demo

Run the included demo to see everything in action:

```bash
cd timeless_metrics_dashboard
mix run examples/demo.exs
# Open http://localhost:4000/dashboard/timeless
```

VM metrics will start populating immediately via `:telemetry_poller`. Use `TIMELESS_DATA_DIR` to persist data across restarts:

```bash
TIMELESS_DATA_DIR=~/.timeless_demo mix run examples/demo.exs
```

## License

MIT
