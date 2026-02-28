defmodule TimelessMetricsDashboard.Page do
  @moduledoc """
  LiveDashboard page plugin for TimelessMetrics.

  Shows four tabs: Overview, Metrics, Alerts, and Storage.

  ## Usage

      # In your router:
      live_dashboard "/dashboard",
        additional_pages: [timeless: {TimelessMetricsDashboard.Page, store: :metrics}]
  """

  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  import TimelessMetricsDashboard.Components

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
      {:ok, "TimelessMetrics (#{info.series_count})"}
    rescue
      _ -> {:disabled, "TimelessMetrics", "Store not running"}
    catch
      :exit, _ -> {:disabled, "TimelessMetrics", "Store not running"}
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
        time_from: nil,
        time_to: nil,
        alerts: [],
        backups: [],
        flash_msg: nil,
        show_alert_form: false,
        editing_alert: nil,
        alert_form: default_alert_form(),
        metric_names: [],
        alert_history: []
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

  def handle_event("show_alert_form", _params, socket) do
    metric_names = load_metric_names(socket.assigns.store)

    {:noreply,
     assign(socket,
       show_alert_form: true,
       editing_alert: nil,
       alert_form: default_alert_form(),
       metric_names: metric_names
     )}
  end

  def handle_event("edit_alert", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    alert = Enum.find(socket.assigns.alerts, &(&1.id == id))
    metric_names = load_metric_names(socket.assigns.store)

    if alert do
      form = %{
        "name" => alert.name,
        "metric" => alert.metric,
        "condition" => alert.condition,
        "threshold" => to_string(alert.threshold),
        "duration" => to_string(alert.duration),
        "aggregate" => alert.aggregate,
        "webhook_url" => alert.webhook_url || ""
      }

      {:noreply,
       assign(socket,
         show_alert_form: true,
         editing_alert: id,
         alert_form: form,
         metric_names: metric_names
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_alert_form", _params, socket) do
    {:noreply, assign(socket, show_alert_form: false, editing_alert: nil, alert_form: default_alert_form())}
  end

  def handle_event("save_alert", params, socket) do
    store = socket.assigns.store

    opts = [
      name: params["name"] || "",
      metric: params["metric"] || "",
      condition: safe_to_atom(params["condition"], ~w(above below), :above),
      threshold: parse_number(params["threshold"]),
      duration: parse_int(params["duration"]),
      aggregate: safe_to_atom(params["aggregate"], ~w(avg min max sum count last first), :avg),
      webhook_url: blank_to_nil(params["webhook_url"])
    ]

    result =
      case socket.assigns.editing_alert do
        nil -> TimelessMetrics.create_alert(store, opts)
        id -> TimelessMetrics.update_alert(store, id, opts)
      end

    case result do
      {:ok, _id} ->
        {:noreply,
         socket
         |> set_flash("Alert created")
         |> assign(show_alert_form: false, editing_alert: nil, alert_form: default_alert_form())
         |> load_alerts()}

      :ok ->
        {:noreply,
         socket
         |> set_flash("Alert updated")
         |> assign(show_alert_form: false, editing_alert: nil, alert_form: default_alert_form())
         |> load_alerts()}

      {:error, reason} ->
        {:noreply, set_flash(socket, "Error: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_alert", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    TimelessMetrics.delete_alert(socket.assigns.store, id)

    {:noreply,
     socket
     |> set_flash("Alert deleted")
     |> load_alerts()}
  end

  def handle_event("toggle_alert", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    alert = Enum.find(socket.assigns.alerts, &(&1.id == id))

    if alert do
      TimelessMetrics.update_alert(socket.assigns.store, id, enabled: !alert.enabled)

      {:noreply,
       socket
       |> set_flash("Alert #{if alert.enabled, do: "disabled", else: "enabled"}")
       |> load_alerts()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("acknowledge_alert", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    TimelessMetrics.acknowledge_alert(socket.assigns.store, id)

    {:noreply,
     socket
     |> set_flash("Alert acknowledged")
     |> load_alerts()}
  end

  def handle_event("clear_alert_history", _params, socket) do
    TimelessMetrics.clear_alert_history(socket.assigns.store, acknowledged_only: true, before: System.os_time(:second) + 1)

    {:noreply,
     socket
     |> set_flash("Acknowledged history cleared")
     |> load_alerts()}
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
            time_from={@time_from}
            time_to={@time_to}
            page={@page}
            socket={@socket}
          />
        <% :alerts -> %>
          <.render_alerts
            alerts={@alerts}
            show_alert_form={@show_alert_form}
            editing_alert={@editing_alert}
            alert_form={@alert_form}
            metric_names={@metric_names}
            alert_history={@alert_history}
          />
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
          {"Blocks", format_number(@info.block_count)},
          {"Buffer Points", format_number(@info.raw_buffer_points)},
          {"Actor Processes", @info.process_count},
          {"Compressed Bytes", format_bytes(@info.compressed_bytes)},
          {"Bytes/Point", @info.bytes_per_point},
          {"Compression Ratio", format_compression_ratio(@info.bytes_per_point)},
          {"Storage", format_bytes(@info.storage_bytes)},
          {"Daily Rollup Rows", format_number(@info.daily_rollup_rows)},
          {"Index ETS", format_bytes(@info.index_ets_bytes)},
          {"Data Span", format_data_span(@info.oldest_timestamp, @info.newest_timestamp)},
          {"Oldest", format_ts(@info.oldest_timestamp)},
          {"Newest", format_ts(@info.newest_timestamp)}
        ]}
      />
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

  defp render_alerts(assigns) do
    ~H"""
    <div>
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
        <h4 style="margin:0;font-size:14px;font-weight:600">Alert Rules</h4>
        <button
          :if={!@show_alert_form}
          phx-click="show_alert_form"
          style="padding:6px 16px;background:#2563eb;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:13px"
        >
          New Alert
        </button>
      </div>

      <div :if={@show_alert_form} style="padding:16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:6px;margin-bottom:16px">
        <h4 style="margin:0 0 12px 0;font-size:14px;font-weight:600;color:#374151">
          <%= if @editing_alert, do: "Edit Alert", else: "New Alert" %>
        </h4>
        <form phx-submit="save_alert">
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:12px">
            <div>
              <label style="display:block;font-size:12px;font-weight:600;color:#374151;margin-bottom:2px">Name *</label>
              <input
                type="text"
                name="name"
                value={@alert_form["name"]}
                required
                placeholder="e.g. high_memory"
                style="width:100%;padding:5px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:13px;box-sizing:border-box"
              />
            </div>
            <div>
              <label style="display:block;font-size:12px;font-weight:600;color:#374151;margin-bottom:2px">Metric *</label>
              <select
                name="metric"
                required
                style="width:100%;padding:5px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:13px;box-sizing:border-box;background:#fff"
              >
                <option value="">Select metric...</option>
                <option :for={m <- @metric_names} value={m} selected={m == @alert_form["metric"]}><%= m %></option>
              </select>
            </div>
            <div>
              <label style="display:block;font-size:12px;font-weight:600;color:#374151;margin-bottom:2px">Condition</label>
              <select
                name="condition"
                style="width:100%;padding:5px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:13px;box-sizing:border-box;background:#fff"
              >
                <option value="above" selected={@alert_form["condition"] == "above"}>above</option>
                <option value="below" selected={@alert_form["condition"] == "below"}>below</option>
              </select>
            </div>
            <div>
              <label style="display:block;font-size:12px;font-weight:600;color:#374151;margin-bottom:2px">Threshold *</label>
              <input
                type="number"
                name="threshold"
                value={@alert_form["threshold"]}
                required
                step="any"
                style="width:100%;padding:5px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:13px;box-sizing:border-box"
              />
            </div>
            <div>
              <label style="display:block;font-size:12px;font-weight:600;color:#374151;margin-bottom:2px">Duration (seconds)</label>
              <input
                type="number"
                name="duration"
                value={@alert_form["duration"]}
                min="0"
                step="1"
                style="width:100%;padding:5px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:13px;box-sizing:border-box"
              />
              <div style="font-size:11px;color:#9ca3af;margin-top:2px">0 = fire immediately</div>
            </div>
            <div>
              <label style="display:block;font-size:12px;font-weight:600;color:#374151;margin-bottom:2px">Aggregate</label>
              <select
                name="aggregate"
                style="width:100%;padding:5px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:13px;box-sizing:border-box;background:#fff"
              >
                <option :for={agg <- ~w(avg min max sum count last first)} value={agg} selected={agg == @alert_form["aggregate"]}><%= agg %></option>
              </select>
            </div>
          </div>
          <div style="margin-bottom:12px">
            <label style="display:block;font-size:12px;font-weight:600;color:#374151;margin-bottom:2px">Webhook URL (optional)</label>
            <input
              type="url"
              name="webhook_url"
              value={@alert_form["webhook_url"]}
              placeholder="https://ntfy.sh/my-alerts"
              style="width:100%;padding:5px 8px;border:1px solid #d1d5db;border-radius:4px;font-size:13px;box-sizing:border-box"
            />
          </div>
          <div style="display:flex;gap:8px">
            <button
              type="submit"
              style="padding:6px 16px;background:#2563eb;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:13px"
            >
              <%= if @editing_alert, do: "Update Alert", else: "Create Alert" %>
            </button>
            <button
              type="button"
              phx-click="cancel_alert_form"
              style="padding:6px 16px;background:#fff;color:#374151;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;font-size:13px"
            >
              Cancel
            </button>
          </div>
        </form>
      </div>

      <div :if={@alerts == []} style="color:#6b7280;font-size:13px">No alert rules configured.</div>
      <table :if={@alerts != []} style="width:100%;border-collapse:collapse;font-size:13px">
        <thead>
          <tr style="border-bottom:2px solid #e5e7eb;text-align:left">
            <th style="padding:6px 8px">Name</th>
            <th style="padding:6px 8px">Metric</th>
            <th style="padding:6px 8px">Condition</th>
            <th style="padding:6px 8px;text-align:right">Threshold</th>
            <th style="padding:6px 8px;text-align:center">State</th>
            <th style="padding:6px 8px;text-align:center">Enabled</th>
            <th style="padding:6px 8px;text-align:right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={alert <- @alerts} style="border-bottom:1px solid #e5e7eb">
            <td style="padding:6px 8px;font-weight:500"><%= alert.name %></td>
            <td style="padding:6px 8px;font-family:monospace;font-size:12px"><%= alert.metric %></td>
            <td style="padding:6px 8px"><%= alert.condition %></td>
            <td style="padding:6px 8px;text-align:right"><%= format_number(alert.threshold) %></td>
            <td style="padding:6px 8px;text-align:center">
              <% state = worst_alert_state(alert) %>
              <span style={"display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;" <>
                alert_state_style(state)}>
                <%= state %>
              </span>
            </td>
            <td style="padding:6px 8px;text-align:center">
              <button
                phx-click="toggle_alert"
                phx-value-id={alert.id}
                style={"padding:2px 10px;border-radius:10px;font-size:11px;font-weight:600;cursor:pointer;border:none;" <>
                  if(alert.enabled, do: "background:#dcfce7;color:#166534;", else: "background:#f3f4f6;color:#9ca3af;")}
              >
                <%= if alert.enabled, do: "on", else: "off" %>
              </button>
            </td>
            <td style="padding:6px 8px;text-align:right;white-space:nowrap">
              <button
                phx-click="edit_alert"
                phx-value-id={alert.id}
                style="padding:3px 8px;background:#fff;color:#2563eb;border:1px solid #2563eb;border-radius:4px;cursor:pointer;font-size:12px;margin-right:4px"
              >
                Edit
              </button>
              <button
                phx-click="delete_alert"
                phx-value-id={alert.id}
                data-confirm="Delete this alert rule?"
                style="padding:3px 8px;background:#fff;color:#dc2626;border:1px solid #dc2626;border-radius:4px;cursor:pointer;font-size:12px"
              >
                Delete
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <div style="margin-top:24px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
          <h4 style="margin:0;font-size:14px;font-weight:600">Recent Activity</h4>
          <button
            :if={Enum.any?(@alert_history, & &1.acknowledged)}
            phx-click="clear_alert_history"
            data-confirm="Remove all acknowledged history entries?"
            style="padding:4px 12px;background:#f3f4f6;color:#374151;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;font-size:12px"
          >
            Clear Acknowledged
          </button>
        </div>
        <div :if={@alert_history == []} style="color:#6b7280;font-size:13px">No alert history yet.</div>
        <table :if={@alert_history != []} style="width:100%;border-collapse:collapse;font-size:13px">
          <thead>
            <tr style="border-bottom:2px solid #e5e7eb;text-align:left">
              <th style="padding:6px 8px">Time</th>
              <th style="padding:6px 8px">Alert Name</th>
              <th style="padding:6px 8px">Metric</th>
              <th style="padding:6px 8px">Series</th>
              <th style="padding:6px 8px;text-align:center">State</th>
              <th style="padding:6px 8px;text-align:right">Value</th>
              <th style="padding:6px 8px;text-align:center">Ack'd</th>
              <th style="padding:6px 8px;text-align:right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @alert_history} style="border-bottom:1px solid #e5e7eb">
              <td style="padding:6px 8px;font-family:monospace;font-size:11px;white-space:nowrap"><%= format_ts(entry.created_at) %></td>
              <td style="padding:6px 8px;font-weight:500"><%= entry.rule_name %></td>
              <td style="padding:6px 8px;font-family:monospace;font-size:12px"><%= entry.metric %></td>
              <td style="padding:6px 8px;font-family:monospace;font-size:11px"><%= format_labels(entry.series_labels) %></td>
              <td style="padding:6px 8px;text-align:center">
                <span style={"display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;" <>
                  alert_state_style(entry.state)}>
                  <%= entry.state %>
                </span>
              </td>
              <td style="padding:6px 8px;text-align:right;font-family:monospace;font-size:12px">
                <%= if entry.value, do: format_number(entry.value), else: "—" %>
              </td>
              <td style="padding:6px 8px;text-align:center">
                <%= if entry.acknowledged, do: "✓", else: "—" %>
              </td>
              <td style="padding:6px 8px;text-align:right">
                <button
                  :if={!entry.acknowledged}
                  phx-click="acknowledge_alert"
                  phx-value-id={entry.id}
                  style="padding:3px 8px;background:#fff;color:#2563eb;border:1px solid #2563eb;border-radius:4px;cursor:pointer;font-size:12px"
                >
                  Ack
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
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
          {"Total Storage", format_bytes(@info.storage_bytes)}
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
          assign(socket, chart_svg: svg, data_extent: data_extent, time_from: from, time_to: now)

        _ ->
          assign(socket, chart_svg: nil, data_extent: nil, time_from: from, time_to: now)
      end
    else
      assign(socket, chart_svg: nil, data_extent: nil, time_from: nil, time_to: nil)
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
    store = socket.assigns.store

    alerts =
      case TimelessMetrics.list_alerts(store) do
        {:ok, alerts} -> alerts
        _ -> []
      end

    history =
      case TimelessMetrics.alert_history(store, limit: 50) do
        {:ok, entries} -> entries
        _ -> []
      end

    assign(socket, alerts: alerts, alert_history: history)
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

  defp enrich_info(info), do: info

  # --- Formatters ---

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 2)} MB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 2)} KB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "—"

  # 16 bytes per raw point (8-byte timestamp + 8-byte value)
  defp format_compression_ratio(bpp) when is_number(bpp) and bpp > 0 do
    ratio = 16 / bpp
    pct = Float.round((1 - bpp / 16) * 100, 1)
    "#{Float.round(ratio, 1)}x (#{pct}% smaller)"
  end

  defp format_compression_ratio(_), do: "—"

  defp format_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_number(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)

  defp format_number(n) when is_float(n) do
    # If it's a whole number stored as float, format as integer
    if n == Float.floor(n) and abs(n) < 1.0e15 do
      format_number(trunc(n))
    else
      Float.to_string(Float.round(n, 2))
    end
  end

  defp format_number(_), do: "—"

  defp format_ts(nil), do: "—"

  defp format_ts(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "#{ts}"
    end
  end

  defp format_ts(ts), do: "#{ts}"

  defp format_data_span(oldest, newest) when is_integer(oldest) and is_integer(newest) do
    span = newest - oldest
    age = System.os_time(:second) - newest

    span_str = format_duration_human(span)
    age_str = if age < 60, do: "live", else: "#{format_duration_human(age)} ago"

    "#{span_str} (latest: #{age_str})"
  end

  defp format_data_span(_, _), do: "—"

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

  defp format_labels(labels) when is_map(labels) do
    labels
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(", ")
  end

  defp format_labels(_), do: "—"

  defp alert_state_style("ok"), do: "background:#dcfce7;color:#166534;"
  defp alert_state_style("firing"), do: "background:#fee2e2;color:#991b1b;"
  defp alert_state_style("pending"), do: "background:#fef3c7;color:#92400e;"
  defp alert_state_style("resolved"), do: "background:#dbeafe;color:#1e40af;"
  defp alert_state_style(_), do: "background:#f3f4f6;color:#374151;"

  defp worst_alert_state(alert) do
    states = Enum.map(alert.states, & &1.state)

    cond do
      "firing" in states -> "firing"
      "pending" in states -> "pending"
      "resolved" in states -> "resolved"
      true -> "ok"
    end
  end

  defp default_alert_form do
    %{
      "name" => "",
      "metric" => "",
      "condition" => "above",
      "threshold" => "",
      "duration" => "0",
      "aggregate" => "avg",
      "webhook_url" => ""
    }
  end

  defp load_metric_names(store) do
    case TimelessMetrics.list_metrics(store) do
      {:ok, list} -> list
      _ -> []
    end
  end

  defp parse_number(nil), do: 0.0
  defp parse_number(""), do: 0.0

  defp parse_number(str) when is_binary(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> 0.0
    end
  end

  defp parse_number(n) when is_number(n), do: n * 1.0

  defp parse_int(nil), do: 0
  defp parse_int(""), do: 0

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(str), do: str

  defp safe_to_atom(val, allowed, default) when is_binary(val) do
    if val in allowed, do: String.to_atom(val), else: default
  end

  defp safe_to_atom(_, _allowed, default), do: default

end
