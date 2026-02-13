defmodule TimelessDashboard.Page do
  @moduledoc """
  LiveDashboard page plugin for TimelessMetrics.

  Shows four tabs: Overview, Metrics, Alerts, and Storage.

  ## Usage

      # In your router:
      live_dashboard "/dashboard",
        additional_pages: [timeless: {TimelessDashboard.Page, store: :metrics}]
  """

  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  import TimelessDashboard.Components

  @time_ranges %{
    "15m" => 900,
    "1h" => 3600,
    "6h" => 21_600,
    "24h" => 86_400,
    "7d" => 604_800
  }

  # ~200 data points per chart
  @target_buckets 200

  # --- PageBuilder callbacks ---

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    chart_width = Keyword.get(opts, :chart_width, 700)
    chart_height = Keyword.get(opts, :chart_height, 250)

    download_path = Keyword.get(opts, :download_path)

    session = %{
      store: store,
      chart_width: chart_width,
      chart_height: chart_height,
      download_path: download_path
    }

    {:ok, session}
  end

  @impl true
  def menu_link(session, _capabilities) do
    store = session.store

    try do
      info = TimelessMetrics.info(store)
      {:ok, "Timeless (#{info.series_count})"}
    rescue
      _ -> {:disabled, "Timeless", "Store not running"}
    catch
      :exit, _ -> {:disabled, "Timeless", "Store not running"}
    end
  end

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(
        store: session.store,
        chart_width: session.chart_width,
        chart_height: session.chart_height,
        download_path: Map.get(session, :download_path),
        active_tab: :overview,
        time_range: "1h",
        selected_metric: nil,
        metric_search: "",
        info: nil,
        metrics_list: [],
        chart_svg: nil,
        data_extent: nil,
        alerts: [],
        backups: [],
        flash_msg: nil
      )
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    socket =
      socket
      |> assign(active_tab: String.to_existing_atom(tab))
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("select_time_range", %{"range" => range}, socket) do
    socket =
      socket
      |> assign(time_range: range)
      |> load_chart()

    {:noreply, socket}
  end

  def handle_event("search_metrics", %{"search" => search}, socket) do
    {:noreply, assign(socket, metric_search: search)}
  end

  def handle_event("select_metric", %{"metric" => metric}, socket) do
    socket =
      socket
      |> assign(selected_metric: metric)
      |> load_chart()

    {:noreply, socket}
  end

  def handle_event("trigger_backup", _params, socket) do
    store = socket.assigns.store
    info = TimelessMetrics.info(store)
    data_dir = Path.dirname(info.db_path)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    target = Path.join([data_dir, "backups", timestamp])

    try do
      {:ok, result} = TimelessMetrics.backup(store, target)
      size = format_bytes(result.total_bytes)

      {:noreply,
       socket
       |> set_flash("Backup created: #{length(result.files)} files, #{size}")
       |> load_storage()}
    rescue
      e -> {:noreply, set_flash(socket, "Backup failed: #{Exception.message(e)}")}
    end
  end

  def handle_event("flush_store", _params, socket) do
    TimelessMetrics.flush(socket.assigns.store)
    {:noreply, socket |> set_flash("Store flushed") |> load_data()}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div style="display:flex;gap:8px;margin-bottom:16px">
        <button
          :for={tab <- [:overview, :metrics, :alerts, :storage]}
          phx-click="select_tab"
          phx-value-tab={tab}
          style={"padding:6px 16px;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;font-size:13px;" <>
            if(tab == @active_tab, do: "background:#2563eb;color:#fff;border-color:#2563eb;", else: "background:#fff;color:#374151;")}
        >
          <%= tab |> to_string() |> String.capitalize() %>
        </button>
      </div>

      <div :if={@flash_msg} style="display:flex;align-items:center;justify-content:space-between;padding:8px 12px;margin-bottom:12px;background:#dbeafe;border:1px solid #93c5fd;border-radius:4px;font-size:13px;color:#1e40af">
        <span><%= @flash_msg %></span>
        <button phx-click="dismiss_flash" style="background:none;border:none;cursor:pointer;color:#1e40af;font-size:16px;padding:0 0 0 12px;line-height:1">&times;</button>
      </div>

      <%= case @active_tab do %>
        <% :overview -> %>
          <.render_overview info={@info} />
        <% :metrics -> %>
          <.render_metrics
            metrics_list={@metrics_list}
            selected_metric={@selected_metric}
            time_range={@time_range}
            chart_svg={@chart_svg}
            data_extent={@data_extent}
            store={@store}
            metric_search={@metric_search}
          />
        <% :alerts -> %>
          <.render_alerts alerts={@alerts} />
        <% :storage -> %>
          <.render_storage info={@info} backups={@backups} download_path={@download_path} />
      <% end %>
    </div>
    """
  end

  # --- Tab renders ---

  defp render_overview(assigns) do
    ~H"""
    <div :if={@info}>
      <.fields_card
        title="Store Statistics"
        fields={[
          {"Series", @info.series_count},
          {"Total Points", format_number(@info.total_points)},
          {"Segment Points", format_number(@info.segment_points)},
          {"Pending Points", format_number(@info.pending_points)},
          {"Buffer Points", @info.buffer_points},
          {"Compression", format_ratio(@info.bytes_per_point)},
          {"Bytes/Point", @info.bytes_per_point},
          {"Disk Usage", format_bytes(@info.disk_bytes)},
          {"Disk Bytes/Point", @info.disk_bytes_per_point},
          {"Buffer Shards", @info.buffer_shards},
          {"Data Span", format_data_span(@info.oldest_timestamp, @info.newest_timestamp)},
          {"Oldest", format_ts(@info.oldest_timestamp)},
          {"Newest", format_ts(@info.newest_timestamp)}
        ]}
      />

      <div :if={@info.tiers != %{}} style="margin-top:16px">
        <h4 style="font-size:14px;font-weight:600;margin-bottom:8px">Rollup Tiers</h4>
        <table style="width:100%;border-collapse:collapse;font-size:13px">
          <thead>
            <tr style="border-bottom:2px solid #e5e7eb;text-align:left">
              <th style="padding:6px 8px">Tier</th>
              <th style="padding:6px 8px">Resolution</th>
              <th style="padding:6px 8px">Retention</th>
              <th style="padding:6px 8px;text-align:right">Rows</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{name, tier} <- @info.tiers} style="border-bottom:1px solid #e5e7eb">
              <td style="padding:6px 8px;font-family:monospace"><%= name %></td>
              <td style="padding:6px 8px"><%= format_duration(tier.resolution_seconds) %></td>
              <td style="padding:6px 8px"><%= tier.retention %></td>
              <td style="padding:6px 8px;text-align:right"><%= format_number(tier.rows) %></td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    <div :if={!@info} style="color:#6b7280;font-size:13px">Store not available.</div>
    """
  end

  defp render_metrics(assigns) do
    filtered =
      if assigns.metric_search == "" do
        assigns.metrics_list
      else
        needle = String.downcase(assigns.metric_search)
        Enum.filter(assigns.metrics_list, &String.contains?(String.downcase(&1), needle))
      end

    grouped = group_metrics_by_prefix(filtered)
    assigns = assign(assigns, filtered: filtered, grouped: grouped)

    ~H"""
    <div style="display:flex;gap:16px">
      <div style="width:240px;flex-shrink:0">
        <h4 style="font-size:14px;font-weight:600;margin:0 0 8px 0">
          Metrics
          <span :if={@metrics_list != []} style="font-weight:400;color:#9ca3af;font-size:12px">
            (<%= length(@filtered) %>/<%= length(@metrics_list) %>)
          </span>
        </h4>
        <form phx-change="search_metrics" style="margin-bottom:8px">
          <input
            type="text"
            name="search"
            value={@metric_search}
            placeholder="Filter metrics..."
            phx-debounce="150"
            autocomplete="off"
            style="width:100%;padding:4px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:12px;box-sizing:border-box"
          />
        </form>
        <div :if={@metrics_list == []} style="color:#6b7280;font-size:13px">No metrics yet.</div>
        <div :if={@filtered == [] && @metrics_list != []} style="color:#6b7280;font-size:13px">No matches.</div>
        <div style="max-height:500px;overflow-y:auto">
          <div :for={{prefix, metrics} <- @grouped} style="margin-bottom:6px">
            <div style="font-size:11px;font-weight:600;color:#9ca3af;padding:2px 8px;text-transform:uppercase;letter-spacing:0.5px">
              <%= prefix %>
            </div>
            <div
              :for={metric <- metrics}
              phx-click="select_metric"
              phx-value-metric={metric}
              style={"padding:3px 8px 3px 16px;cursor:pointer;border-radius:4px;font-size:12px;font-family:monospace;word-break:break-all;" <>
                if(metric == @selected_metric, do: "background:#dbeafe;color:#1e40af;", else: "color:#374151;")}
            >
              <%= short_metric_name(metric, prefix) %>
            </div>
          </div>
        </div>
      </div>

      <div style="flex:1;min-width:0">
        <.time_picker selected={@time_range} />

        <div :if={@data_extent} style="font-size:12px;color:#9ca3af;margin:4px 0">
          <%= @data_extent %>
        </div>

        <div :if={@chart_svg}>
          <.chart_embed svg={@chart_svg} />
        </div>

        <div :if={@selected_metric && !@chart_svg} style="color:#6b7280;font-size:13px;padding:20px 0">
          No data for this metric in the selected time range.
        </div>

        <div :if={!@selected_metric} style="color:#6b7280;font-size:13px;padding:20px 0">
          Select a metric from the sidebar.
        </div>

        <.render_metric_metadata store={@store} metric={@selected_metric} />
      </div>
    </div>
    """
  end

  defp render_metric_metadata(assigns) do
    metadata =
      if assigns.metric do
        case TimelessMetrics.get_metadata(assigns.store, assigns.metric) do
          {:ok, meta} -> meta
          _ -> nil
        end
      end

    assigns = assign(assigns, :metadata, metadata)

    ~H"""
    <div :if={@metadata} style="margin-top:12px;padding:8px 12px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:4px;font-size:12px">
      <span :if={@metadata.type} style="margin-right:12px"><strong>Type:</strong> <%= @metadata.type %></span>
      <span :if={@metadata.unit} style="margin-right:12px"><strong>Unit:</strong> <%= @metadata.unit %></span>
      <span :if={@metadata.description}><strong>Description:</strong> <%= @metadata.description %></span>
    </div>
    """
  end

  @alert_examples [
    %{
      title: "Alert when VM memory exceeds 512 MB:",
      code: """
      TimelessMetrics.create_alert(:metrics,
        name: "high_memory",
        metric: "telemetry.vm.memory.total",
        condition: :above,
        threshold: 512_000_000,
        duration: 60
      )\
      """
    },
    %{
      title: "Alert when process count drops below 10:",
      code: """
      TimelessMetrics.create_alert(:metrics,
        name: "low_processes",
        metric: "telemetry.vm.system_counts.process_count",
        condition: :below,
        threshold: 10
      )\
      """
    },
    %{
      title: "Alert with webhook (ntfy.sh, Slack, etc.):",
      code: """
      TimelessMetrics.create_alert(:metrics,
        name: "high_request_latency",
        metric: "telemetry.phoenix.endpoint.stop.duration",
        condition: :above,
        threshold: 500,
        duration: 120,
        aggregate: :avg,
        webhook_url: "https://ntfy.sh/my-alerts"
      )\
      """
    }
  ]

  defp render_alerts(assigns) do
    assigns = assign(assigns, :examples, @alert_examples)

    ~H"""
    <div :if={@alerts == []} style="color:#6b7280;font-size:13px;margin-bottom:16px">No alert rules configured.</div>
    <table :if={@alerts != []} style="width:100%;border-collapse:collapse;font-size:13px;margin-bottom:16px">
      <thead>
        <tr style="border-bottom:2px solid #e5e7eb;text-align:left">
          <th style="padding:6px 8px">Name</th>
          <th style="padding:6px 8px">Metric</th>
          <th style="padding:6px 8px">Condition</th>
          <th style="padding:6px 8px;text-align:right">Threshold</th>
          <th style="padding:6px 8px;text-align:center">State</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={alert <- @alerts} style="border-bottom:1px solid #e5e7eb">
          <td style="padding:6px 8px;font-weight:500"><%= alert.name %></td>
          <td style="padding:6px 8px;font-family:monospace;font-size:12px"><%= alert.metric %></td>
          <td style="padding:6px 8px"><%= alert.condition %></td>
          <td style="padding:6px 8px;text-align:right"><%= alert.threshold %></td>
          <td style="padding:6px 8px;text-align:center">
            <span style={"display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;" <>
              alert_state_style(alert.state)}>
              <%= alert.state %>
            </span>
          </td>
        </tr>
      </tbody>
    </table>

    <div style="margin-top:8px;padding:16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:6px">
      <h4 style="margin:0 0 12px 0;font-size:14px;font-weight:600;color:#374151">Creating Alerts</h4>
      <p style="margin:0 0 12px 0;font-size:13px;color:#6b7280;line-height:1.5">
        Alert rules are created via the Timeless API. Add them in your application startup
        or create them at any time from an IEx session.
      </p>

      <div :for={example <- @examples} style="margin-bottom:12px">
        <div style="font-size:12px;font-weight:600;color:#374151;margin-bottom:4px"><%= example.title %></div>
        <pre style="margin:0;padding:10px;background:#1f2937;color:#e5e7eb;border-radius:4px;font-size:12px;overflow-x:auto;line-height:1.5"><%= String.trim(example.code) %></pre>
      </div>

      <p style="margin:12px 0 0 0;font-size:12px;color:#9ca3af;line-height:1.5">
        <strong>Options:</strong>
        <code>:name</code>, <code>:metric</code>, <code>:condition</code> (<code>:above</code> | <code>:below</code>),
        <code>:threshold</code>, <code>:duration</code> (seconds before firing, default 0),
        <code>:labels</code> (filter map), <code>:aggregate</code> (default <code>:avg</code>),
        <code>:webhook_url</code> (POST on state change).
        Delete with <code>TimelessMetrics.delete_alert(:metrics, rule_id)</code>.
      </p>
    </div>
    """
  end

  defp render_storage(assigns) do
    ~H"""
    <div :if={@info}>
      <.fields_card
        title="Database"
        fields={[
          {"Path", @info.db_path},
          {"Total DB Size", format_bytes(@info.disk_bytes)},
          {"Raw Retention", format_duration(@info.raw_retention)}
        ]}
      />

      <div style="margin-top:16px;display:flex;gap:8px">
        <button
          phx-click="trigger_backup"
          style="padding:6px 16px;background:#2563eb;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:13px"
        >
          Create Backup
        </button>
        <button
          phx-click="flush_store"
          style="padding:6px 16px;background:#f3f4f6;color:#374151;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;font-size:13px"
        >
          Flush to Disk
        </button>
      </div>

      <div :if={@backups != []} style="margin-top:16px">
        <h4 style="font-size:14px;font-weight:600;margin-bottom:8px">Recent Backups</h4>
        <table style="width:100%;border-collapse:collapse;font-size:13px">
          <thead>
            <tr style="border-bottom:2px solid #e5e7eb;text-align:left">
              <th style="padding:6px 8px">Timestamp</th>
              <th style="padding:6px 8px;text-align:right">Files</th>
              <th style="padding:6px 8px;text-align:right">Size</th>
              <th :if={@download_path} style="padding:6px 8px;text-align:center">Download</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={backup <- @backups} style="border-bottom:1px solid #e5e7eb">
              <td style="padding:6px 8px;font-family:monospace"><%= backup.name %></td>
              <td style="padding:6px 8px;text-align:right"><%= backup.file_count %></td>
              <td style="padding:6px 8px;text-align:right"><%= format_bytes(backup.total_bytes) %></td>
              <td :if={@download_path} style="padding:6px 8px;text-align:center">
                <a
                  href={"#{@download_path}/backups/#{backup.name}"}
                  download
                  target="_blank"
                  style="color:#2563eb;text-decoration:none;font-size:12px"
                >tar.gz</a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p style="margin-top:16px;font-size:12px;color:#9ca3af;line-height:1.5">
        Backups are stored on disk at <code style="background:#f3f4f6;padding:2px 4px;border-radius:3px"><%= Path.dirname(@info.db_path) %>/backups/</code>
      </p>
    </div>
    <div :if={!@info} style="color:#6b7280;font-size:13px">Store not available.</div>
    """
  end

  # --- Data loading ---

  defp load_data(socket) do
    store = socket.assigns.store

    case safe_info(store) do
      nil ->
        assign(socket, info: nil, metrics_list: [], alerts: [], backups: [])

      info ->
        info = enrich_info(info)

        socket
        |> assign(info: info)
        |> load_tab_data()
    end
  end

  defp load_tab_data(socket) do
    case socket.assigns.active_tab do
      :overview -> socket
      :metrics -> load_metrics_tab(socket)
      :alerts -> load_alerts(socket)
      :storage -> load_storage(socket)
    end
  end

  defp load_metrics_tab(socket) do
    store = socket.assigns.store

    metrics_list =
      case TimelessMetrics.list_metrics(store) do
        {:ok, list} -> list
        _ -> []
      end

    selected =
      cond do
        socket.assigns.selected_metric in metrics_list -> socket.assigns.selected_metric
        metrics_list != [] -> hd(metrics_list)
        true -> nil
      end

    socket
    |> assign(metrics_list: metrics_list, selected_metric: selected)
    |> load_chart()
  end

  defp load_chart(socket) do
    store = socket.assigns.store
    metric = socket.assigns.selected_metric

    if metric do
      range_seconds = Map.get(@time_ranges, socket.assigns.time_range, 3600)
      now = System.os_time(:second)
      from = now - range_seconds
      bucket_seconds = max(div(range_seconds, @target_buckets), 1)

      case TimelessMetrics.query_aggregate_multi(store, metric, %{},
             from: from,
             to: now,
             bucket: {bucket_seconds, :seconds},
             aggregate: :avg
           ) do
        {:ok, series} when series != [] ->
          svg =
            TimelessMetrics.Chart.render(metric, series,
              width: socket.assigns.chart_width,
              height: socket.assigns.chart_height,
              theme: :auto
            )

          data_extent = compute_data_extent(series, range_seconds)
          assign(socket, chart_svg: svg, data_extent: data_extent)

        _ ->
          assign(socket, chart_svg: nil, data_extent: nil)
      end
    else
      assign(socket, chart_svg: nil, data_extent: nil)
    end
  end

  # Returns a hint string if data covers <75% of the selected range, nil otherwise
  defp compute_data_extent(series, range_seconds) do
    timestamps =
      Enum.flat_map(series, fn %{data: data} ->
        Enum.map(data, fn {ts, _val} -> ts end)
      end)

    case {Enum.min(timestamps, fn -> nil end), Enum.max(timestamps, fn -> nil end)} do
      {nil, _} ->
        nil

      {_, nil} ->
        nil

      {min_ts, max_ts} ->
        actual = max_ts - min_ts

        if actual < range_seconds * 0.75 do
          "Showing #{format_duration_human(actual)} of #{format_duration_human(range_seconds)}"
        end
    end
  end

  defp format_duration_human(seconds) when seconds >= 86_400 do
    days = Float.round(seconds / 86_400, 1)
    if days == Float.round(days), do: "#{trunc(days)}d", else: "#{days}d"
  end

  defp format_duration_human(seconds) when seconds >= 3600 do
    hours = Float.round(seconds / 3600, 1)
    if hours == Float.round(hours), do: "#{trunc(hours)}h", else: "#{hours}h"
  end

  defp format_duration_human(seconds) when seconds >= 60 do
    mins = Float.round(seconds / 60, 1)
    if mins == Float.round(mins), do: "#{trunc(mins)}m", else: "#{mins}m"
  end

  defp format_duration_human(seconds), do: "#{seconds}s"

  defp load_alerts(socket) do
    case TimelessMetrics.list_alerts(socket.assigns.store) do
      {:ok, alerts} -> assign(socket, alerts: alerts)
      _ -> assign(socket, alerts: [])
    end
  end

  defp load_storage(socket) do
    info = socket.assigns.info

    backups =
      if info do
        data_dir = Path.dirname(info.db_path)
        backup_dir = Path.join(data_dir, "backups")

        if File.dir?(backup_dir) do
          backup_dir
          |> File.ls!()
          |> Enum.sort(:desc)
          |> Enum.take(20)
          |> Enum.map(fn name ->
            path = Path.join(backup_dir, name)

            {file_count, total_bytes} =
              if File.dir?(path) do
                files = File.ls!(path)

                total =
                  Enum.reduce(files, 0, fn f, acc ->
                    case File.stat(Path.join(path, f)) do
                      {:ok, %{size: size}} -> acc + size
                      _ -> acc
                    end
                  end)

                {length(files), total}
              else
                {0, 0}
              end

            %{name: name, file_count: file_count, total_bytes: total_bytes}
          end)
        else
          []
        end
      else
        []
      end

    assign(socket, backups: backups)
  end

  defp set_flash(socket, msg) do
    Process.send_after(self(), :clear_flash, 5_000)
    assign(socket, flash_msg: msg)
  end

  defp safe_info(store) do
    TimelessMetrics.info(store)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Add derived fields for display (storage_bytes already includes all shard DBs)
  defp enrich_info(info) do
    disk_bytes_per_point =
      if info.total_points > 0,
        do: Float.round(info.storage_bytes / info.total_points, 2),
        else: 0.0

    Map.merge(info, %{
      disk_bytes: info.storage_bytes,
      disk_bytes_per_point: disk_bytes_per_point
    })
  end

  # --- Formatters ---

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 2)} MB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 2)} KB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "—"

  defp format_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_number(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_float(n), do: Float.to_string(Float.round(n, 2))
  defp format_number(_), do: "—"

  defp format_ts(nil), do: "—"

  defp format_ts(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "#{ts}"
    end
  end

  defp format_ts(ts), do: "#{ts}"

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds >= 86_400 -> "#{div(seconds, 86_400)}d"
      seconds >= 3600 -> "#{div(seconds, 3600)}h"
      seconds >= 60 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  defp format_duration(:forever), do: "forever"
  defp format_duration(_), do: "—"

  defp format_data_span(oldest, newest) when is_integer(oldest) and is_integer(newest) do
    span = newest - oldest
    age = System.os_time(:second) - newest

    span_str = format_duration_human(span)
    age_str = if age < 60, do: "live", else: "#{format_duration_human(age)} ago"

    "#{span_str} (latest: #{age_str})"
  end

  defp format_data_span(_, _), do: "—"

  # 16 bytes uncompressed per point (8-byte timestamp + 8-byte float64)
  defp format_ratio(bpp) when is_number(bpp) and bpp > 0,
    do: "#{Float.round(16 / bpp, 1)}:1 (#{Float.round(100 - bpp / 16 * 100, 1)}% smaller)"

  defp format_ratio(_), do: "—"

  # Group metrics by their first two dotted segments (e.g. "telemetry.vm")
  # Returns [{prefix, [full_metric_name, ...]}, ...] sorted by prefix
  defp group_metrics_by_prefix(metrics) do
    metrics
    |> Enum.group_by(fn name ->
      case String.split(name, ".", parts: 3) do
        [a, b | _] -> "#{a}.#{b}"
        _ -> name
      end
    end)
    |> Enum.sort_by(fn {prefix, _} -> prefix end)
  end

  # Strip the group prefix from the metric name for compact sidebar display
  defp short_metric_name(metric, prefix) do
    case String.trim_leading(metric, prefix <> ".") do
      ^metric -> metric
      short -> short
    end
  end

  defp alert_state_style("ok"), do: "background:#dcfce7;color:#166534;"
  defp alert_state_style("firing"), do: "background:#fee2e2;color:#991b1b;"
  defp alert_state_style("pending"), do: "background:#fef3c7;color:#92400e;"
  defp alert_state_style(_), do: "background:#f3f4f6;color:#374151;"
end
