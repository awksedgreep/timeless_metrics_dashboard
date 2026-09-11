if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
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
    @default_metric_page_size 200
    @default_max_chart_series 20
    @max_series_options 100
    @storage_cache_ms 60_000
    @backup_cooldown_ms 30_000

    # --- PageBuilder callbacks ---

    @impl true
    def init(opts) do
      store = Keyword.fetch!(opts, :store)
      chart_width = Keyword.get(opts, :chart_width, 700)
      chart_height = Keyword.get(opts, :chart_height, 250)

      metric_page_size =
        positive_integer_option(opts, :metric_page_size, @default_metric_page_size)

      max_chart_series =
        positive_integer_option(opts, :max_chart_series, @default_max_chart_series)

      download_path = Keyword.get(opts, :download_path)

      session = %{
        store: store,
        chart_width: chart_width,
        chart_height: chart_height,
        metric_page_size: metric_page_size,
        max_chart_series: max_chart_series,
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
          metric_page_size: Map.get(session, :metric_page_size, @default_metric_page_size),
          max_chart_series: Map.get(session, :max_chart_series, @default_max_chart_series),
          download_path: Map.get(session, :download_path),
          active_tab: :overview,
          time_range: "1h",
          selected_metric: nil,
          metric_search: "",
          metric_page: 1,
          metric_page_count: 1,
          metric_filtered_total: 0,
          metric_groups: [],
          info: nil,
          metrics_list: [],
          chart_data_uri: nil,
          chart_hash: nil,
          chart_series_options: [],
          chart_series_total: 0,
          chart_series_filter: nil,
          metric_metadata: nil,
          metadata_metric: nil,
          data_extent: nil,
          time_from: nil,
          time_to: nil,
          alerts: [],
          backups: [],
          storage_loaded_at: nil,
          backup_task: nil,
          last_backup_at: nil,
          flush_task: nil,
          flash_msg: nil,
          flash_timer: nil,
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
      case parse_tab(tab) do
        {:ok, active_tab} ->
          socket =
            socket
            |> assign(active_tab: active_tab)
            |> maybe_expire_storage_cache(active_tab)
            |> load_data()

          {:noreply, socket}

        :error ->
          {:noreply, socket}
      end
    end

    def handle_event("select_time_range", %{"range" => range}, socket) do
      if Map.has_key?(@time_ranges, range) do
        socket =
          socket
          |> assign(time_range: range, chart_hash: nil)
          |> load_chart()

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end

    def handle_event("search_metrics", %{"search" => search}, socket) do
      {:noreply,
       socket
       |> assign(metric_search: search, metric_page: 1)
       |> update_metric_page()}
    end

    def handle_event("previous_metrics_page", _params, socket) do
      {:noreply,
       socket
       |> assign(metric_page: max(socket.assigns.metric_page - 1, 1))
       |> update_metric_page()}
    end

    def handle_event("next_metrics_page", _params, socket) do
      {:noreply,
       socket
       |> assign(
         metric_page: min(socket.assigns.metric_page + 1, socket.assigns.metric_page_count)
       )
       |> update_metric_page()}
    end

    def handle_event("select_metric", %{"metric" => metric}, socket) do
      if metric in socket.assigns.metrics_list do
        socket =
          socket
          |> assign(
            selected_metric: metric,
            chart_series_filter: nil,
            chart_series_options: [],
            chart_hash: nil
          )
          |> load_chart()

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end

    def handle_event("select_chart_series", %{"series" => series_key}, socket) do
      valid_keys = Enum.map(socket.assigns.chart_series_options, & &1.key)
      selected = if series_key in valid_keys, do: series_key, else: nil

      {:noreply,
       socket
       |> assign(chart_series_filter: selected, chart_hash: nil)
       |> load_chart()}
    end

    def handle_event("trigger_backup", _params, socket) do
      now = System.monotonic_time(:millisecond)
      last_backup_at = Map.get(socket.assigns, :last_backup_at)

      cond do
        socket.assigns.backup_task ->
          {:noreply, set_flash(socket, "Backup already in progress")}

        is_integer(last_backup_at) && now - last_backup_at < @backup_cooldown_ms ->
          {:noreply, set_flash(socket, "Please wait before creating another backup")}

        true ->
          store = socket.assigns.store
          info = socket.assigns.info

          {:noreply,
           socket
           |> assign(last_backup_at: now)
           |> start_maintenance(:backup, fn -> create_backup(store, info) end)}
      end
    end

    def handle_event("flush_store", _params, socket) do
      if socket.assigns.flush_task do
        {:noreply, set_flash(socket, "Flush already in progress")}
      else
        store = socket.assigns.store
        {:noreply, start_maintenance(socket, :flush, fn -> safe_flush(store) end)}
      end
    end

    def handle_event("dismiss_flash", _params, socket) do
      cancel_timer(socket.assigns.flash_timer)
      {:noreply, assign(socket, flash_msg: nil, flash_timer: nil)}
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
          "webhook_url" => alert.webhook_url || "",
          "webhook_format" => alert.webhook_format || "generic"
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
      {:noreply,
       assign(socket,
         show_alert_form: false,
         editing_alert: nil,
         alert_form: default_alert_form()
       )}
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
        webhook_url: blank_to_nil(params["webhook_url"]),
        webhook_format: safe_string(params["webhook_format"], ~w(generic ntfy), "generic")
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
      TimelessMetrics.clear_alert_history(socket.assigns.store,
        acknowledged_only: true,
        before: System.os_time(:second) + 1
      )

      {:noreply,
       socket
       |> set_flash("Acknowledged history cleared")
       |> load_alerts()}
    end

    @impl true
    def handle_info({:clear_flash, timer_ref}, socket) do
      if socket.assigns.flash_timer && socket.assigns.flash_timer.token == timer_ref do
        {:noreply, assign(socket, flash_msg: nil, flash_timer: nil)}
      else
        {:noreply, socket}
      end
    end

    def handle_info({:maintenance_finished, kind, ref, result}, socket) do
      task = Map.get(socket.assigns, task_assign(kind))

      if task && task.ref == ref do
        Process.demonitor(task.monitor, [:flush])
        {:noreply, finish_maintenance(socket, kind, result)}
      else
        {:noreply, socket}
      end
    end

    def handle_info({:DOWN, monitor, :process, _pid, reason}, socket) do
      case maintenance_kind(socket, monitor) do
        nil -> {:noreply, socket}
        kind -> {:noreply, finish_maintenance(socket, kind, {:error, reason})}
      end
    end

    # --- Render ---

    @impl true
    def render(assigns) do
      ~H"""
      <div class="timeless-metrics-page">
        <ul class="nav nav-pills mb-3">
          <li :for={tab <- [:overview, :metrics, :alerts, :storage]} class="nav-item">
            <button
              phx-click="select_tab"
              phx-value-tab={tab}
              type="button"
              class={"nav-link #{if(tab == @active_tab, do: "active", else: "")}"}
            >
              <%= tab |> to_string() |> String.capitalize() %>
            </button>
          </li>
        </ul>

        <div
          :if={@flash_msg}
          class="alert alert-primary d-flex align-items-center justify-content-between"
          role="alert"
        >
          <span><%= @flash_msg %></span>
          <button phx-click="dismiss_flash" type="button" class="btn-close" aria-label="Dismiss"></button>
        </div>

        <%= case @active_tab do %>
          <% :overview -> %>
            <.render_overview info={@info} />
          <% :metrics -> %>
            <.render_metrics
              metrics_list={@metrics_list}
              metric_groups={@metric_groups}
              metric_filtered_total={@metric_filtered_total}
              metric_page={@metric_page}
              metric_page_count={@metric_page_count}
              selected_metric={@selected_metric}
              time_range={@time_range}
              chart_data_uri={@chart_data_uri}
              chart_series_options={@chart_series_options}
              chart_series_total={@chart_series_total}
              chart_series_filter={@chart_series_filter}
              max_chart_series={@max_chart_series}
              metric_metadata={@metric_metadata}
              data_extent={@data_extent}
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
            <.render_storage
              info={@info}
              backups={@backups}
              download_path={@download_path}
              backup_task={@backup_task}
              flush_task={@flush_task}
            />
        <% end %>
      </div>
      """
    end

    # --- Tab renders ---

    defp render_overview(assigns) do
      ~H"""
      <div :if={@info}>
        <div class="row">
          <.stat_card label="Series" value={format_number(@info.series_count)} />
          <.stat_card label="Total Points" value={format_number(@info.total_points)} />
          <.stat_card
            label="Buffer Points"
            value={format_number(info_value(@info, :raw_buffer_points, :buffer_points, 0))}
          />
          <.stat_card
            label="Blocks"
            value={format_number(info_value(@info, :block_count, :segment_count, 0))}
          />
          <.stat_card
            label="Storage"
            value={format_bytes(info_value(@info, :storage_bytes, :storage_bytes, 0))}
          />
          <.stat_card
            label="Compressed Bytes"
            value={format_bytes(info_value(@info, :compressed_bytes, :raw_compressed_bytes, 0))}
          />
          <.stat_card
            label="Stored Bytes / Point"
            value={format_number(info_value(@info, :bytes_per_point, :bytes_per_point, 0.0))}
          />
          <.stat_card
            label="Compression"
            value={format_compression_status(@info)}
          />
        </div>

        <div class="row mt-2">
          <div class="col-sm-6 mb-3">
            <div class="card h-100">
              <div class="card-body">
                <h6 class="card-subtitle text-muted mb-3">Data Window</h6>
                <dl class="row mb-0" style="font-size: 0.9rem;">
                  <dt class="col-sm-4">Span</dt>
                  <dd class="col-sm-8">{format_data_span(@info[:oldest_timestamp], @info[:newest_timestamp])}</dd>
                  <dt class="col-sm-4">Oldest</dt>
                  <dd class="col-sm-8">{format_ts(@info[:oldest_timestamp])}</dd>
                  <dt class="col-sm-4">Newest</dt>
                  <dd class="col-sm-8">{format_ts(@info[:newest_timestamp])}</dd>
                </dl>
              </div>
            </div>
          </div>

          <div class="col-sm-6 mb-3">
            <div class="card h-100">
              <div class="card-body">
                <h6 class="card-subtitle text-muted mb-3">Engine Details</h6>
                <dl class="row mb-0" style="font-size: 0.9rem;">
                  <dt class="col-sm-5">Points Ingested</dt>
                  <dd class="col-sm-7">{format_number(@info[:points_ingested])}</dd>
                  <dt class="col-sm-5">Daily Rollup Rows</dt>
                  <dd class="col-sm-7">{format_number(info_value(@info, :daily_rollup_rows, :daily_rollup_rows, 0))}</dd>
                  <dt class="col-sm-5">Index Memory</dt>
                  <dd class="col-sm-7">{format_bytes(info_value(@info, :index_ets_bytes, :index_ets_bytes, 0))}</dd>
                  <dt class="col-sm-5">Buffer Memory</dt>
                  <dd class="col-sm-7">{format_bytes(info_value(@info, :buffer_memory_bytes, :buffer_memory_bytes, 0))}</dd>
                  <dt class="col-sm-5">On-Disk Points</dt>
                  <dd class="col-sm-7">{format_number(info_value(@info, :disk_points, :disk_points, 0))}</dd>
                  <dt class="col-sm-5">Processes</dt>
                  <dd class="col-sm-7">{format_number(info_value(@info, :process_count, :process_count, 1))}</dd>
                </dl>
              </div>
            </div>
          </div>
        </div>
      </div>
      <div :if={!@info} class="text-center text-muted py-4">Store not available.</div>
      """
    end

    defp render_metrics(assigns) do
      ~H"""
      <div class="row">
        <div class="col-lg-4 col-xl-3 mb-3">
          <div class="card h-100">
            <div class="card-body">
              <div class="d-flex align-items-center justify-content-between mb-2">
                <h6 class="card-subtitle text-muted mb-0">Metrics</h6>
                <small :if={@metrics_list != []} class="text-muted">
                  <%= @metric_filtered_total %>/<%= length(@metrics_list) %>
                </small>
              </div>

              <form phx-change="search_metrics" class="mb-3">
                <input
                  type="text"
                  name="search"
                  value={@metric_search}
                  placeholder="Filter metrics..."
                  phx-debounce="150"
                  autocomplete="off"
                  class="form-control form-control-sm"
                />
              </form>

              <div :if={@metrics_list == []} class="text-muted small">No metrics yet.</div>
              <div :if={@metric_filtered_total == 0 && @metrics_list != []} class="text-muted small">No matches.</div>

              <div style="max-height: 540px; overflow-y: auto;">
                <div :for={{prefix, metrics} <- @metric_groups} class="mb-3">
                  <div class="text-uppercase text-muted fw-semibold mb-1" style="font-size: 0.7rem; letter-spacing: 0.06em;">
                    <%= prefix %>
                  </div>
                  <button
                    :for={metric <- metrics}
                    phx-click="select_metric"
                    phx-value-metric={metric}
                    type="button"
                    class={"btn btn-sm text-start w-100 mb-1 #{if(metric == @selected_metric, do: "btn-primary", else: "btn-light")}"}
                    style="font-family: monospace; white-space: normal;"
                  >
                    <%= short_metric_name(metric, prefix) %>
                  </button>
                </div>
              </div>

              <div :if={@metric_page_count > 1} class="d-flex align-items-center justify-content-between mt-2">
                <button
                  phx-click="previous_metrics_page"
                  disabled={@metric_page == 1}
                  type="button"
                  class="btn btn-outline-secondary btn-sm"
                >Previous</button>
                <small class="text-muted"><%= @metric_page %>/<%= @metric_page_count %></small>
                <button
                  phx-click="next_metrics_page"
                  disabled={@metric_page == @metric_page_count}
                  type="button"
                  class="btn btn-outline-secondary btn-sm"
                >Next</button>
              </div>
            </div>
          </div>
        </div>

        <div class="col-lg-8 col-xl-9">
          <div class="card mb-3">
            <div class="card-body">
              <div class="d-flex flex-wrap align-items-center justify-content-between mb-3" style="gap: 0.75rem;">
                <div>
                  <h5 class="card-title mb-1"><%= @selected_metric || "Metric Explorer" %></h5>
                  <div class="text-muted small">Average values over the selected window</div>
                  <div :if={is_nil(@chart_series_filter) && @chart_series_total > @max_chart_series} class="text-muted small">
                    Showing the top <%= @max_chart_series %> of <%= @chart_series_total %> series by volume
                  </div>
                </div>
                <div class="d-flex align-items-center" style="gap: 0.5rem;">
                  <select
                    :if={@chart_series_options != []}
                    phx-change="select_chart_series"
                    name="series"
                    aria-label="Chart series"
                    class="form-select form-select-sm"
                  >
                    <option value="" selected={is_nil(@chart_series_filter)}>All (top series)</option>
                    <option
                      :for={option <- @chart_series_options}
                      value={option.key}
                      selected={option.key == @chart_series_filter}
                    ><%= option.label %></option>
                  </select>
                  <.time_picker selected={@time_range} />
                </div>
              </div>

              <div :if={@data_extent} class="text-muted small mb-3">
                <%= @data_extent %>
              </div>

              <div :if={@chart_data_uri}>
                <.chart_embed data_uri={@chart_data_uri} />
              </div>

              <div :if={@selected_metric && !@chart_data_uri} class="text-muted py-4">
                No data for this metric in the selected time range.
              </div>

              <div :if={!@selected_metric} class="text-muted py-4">
                Select a metric from the list to inspect recent values.
              </div>
            </div>
          </div>

          <.render_metric_metadata metadata={@metric_metadata} />
        </div>
      </div>
      """
    end

    defp render_metric_metadata(assigns) do
      ~H"""
      <div :if={@metadata} class="card mb-3">
        <div class="card-body">
          <h6 class="card-subtitle text-muted mb-3">Metric Metadata</h6>
          <dl class="row mb-0" style="font-size: 0.9rem;">
            <dt :if={@metadata.type} class="col-sm-2">Type</dt>
            <dd :if={@metadata.type} class="col-sm-10"><%= @metadata.type %></dd>
            <dt :if={@metadata.unit} class="col-sm-2">Unit</dt>
            <dd :if={@metadata.unit} class="col-sm-10"><%= @metadata.unit %></dd>
            <dt :if={@metadata.description} class="col-sm-2">Description</dt>
            <dd :if={@metadata.description} class="col-sm-10"><%= @metadata.description %></dd>
          </dl>
        </div>
      </div>
      """
    end

    defp render_alerts(assigns) do
      ~H"""
      <div>
        <div class="d-flex align-items-center justify-content-between mb-3">
          <h5 class="mb-0">Alert Rules</h5>
          <button
            :if={!@show_alert_form}
            phx-click="show_alert_form"
            type="button"
            class="btn btn-primary btn-sm"
          >
            New Alert
          </button>
        </div>

        <div :if={@show_alert_form} class="card mb-4">
          <div class="card-body">
          <h6 class="card-subtitle text-muted mb-3">
            <%= if @editing_alert, do: "Edit Alert", else: "New Alert" %>
          </h6>
          <form phx-submit="save_alert">
            <div class="row">
              <div class="col-md-6 mb-3">
                <label class="form-label">Name *</label>
                <input
                  type="text"
                  name="name"
                  value={@alert_form["name"]}
                  required
                  placeholder="e.g. high_memory"
                  class="form-control form-control-sm"
                />
              </div>
              <div class="col-md-6 mb-3">
                <label class="form-label">Metric *</label>
                <select
                  name="metric"
                  required
                  class="form-select form-select-sm"
                >
                  <option value="">Select metric...</option>
                  <option :for={m <- @metric_names} value={m} selected={m == @alert_form["metric"]}><%= m %></option>
                </select>
              </div>
              <div class="col-md-6 mb-3">
                <label class="form-label">Condition</label>
                <select
                  name="condition"
                  class="form-select form-select-sm"
                >
                  <option value="above" selected={@alert_form["condition"] == "above"}>above</option>
                  <option value="below" selected={@alert_form["condition"] == "below"}>below</option>
                </select>
              </div>
              <div class="col-md-6 mb-3">
                <label class="form-label">Threshold *</label>
                <input
                  type="number"
                  name="threshold"
                  value={@alert_form["threshold"]}
                  required
                  step="any"
                  class="form-control form-control-sm"
                />
              </div>
              <div class="col-md-6 mb-3">
                <label class="form-label">Duration (seconds)</label>
                <input
                  type="number"
                  name="duration"
                  value={@alert_form["duration"]}
                  min="0"
                  step="1"
                  class="form-control form-control-sm"
                />
                <div class="form-text">0 = fire immediately</div>
              </div>
              <div class="col-md-6 mb-3">
                <label class="form-label">Aggregate</label>
                <select
                  name="aggregate"
                  class="form-select form-select-sm"
                >
                  <option :for={agg <- ~w(avg min max sum count last first)} value={agg} selected={agg == @alert_form["aggregate"]}><%= agg %></option>
                </select>
              </div>
            </div>
            <div class="row">
              <div class="col-md-8 mb-3">
                <label class="form-label">Webhook URL (optional)</label>
                <input
                  type="url"
                  name="webhook_url"
                  value={@alert_form["webhook_url"]}
                  placeholder="https://ntfy.sh/my-alerts"
                  class="form-control form-control-sm"
                />
              </div>
              <div class="col-md-4 mb-3">
                <label class="form-label">Webhook format</label>
                <select name="webhook_format" class="form-select form-select-sm">
                  <option value="generic" selected={@alert_form["webhook_format"] == "generic"}>generic JSON</option>
                  <option value="ntfy" selected={@alert_form["webhook_format"] == "ntfy"}>ntfy</option>
                </select>
                <div class="form-text">ntfy accepts a topic URL and normalizes it automatically.</div>
              </div>
            </div>
            <div class="d-flex" style="gap: 0.5rem;">
              <button
                type="submit"
                class="btn btn-primary btn-sm"
              >
                <%= if @editing_alert, do: "Update Alert", else: "Create Alert" %>
              </button>
              <button
                type="button"
                phx-click="cancel_alert_form"
                class="btn btn-outline-secondary btn-sm"
              >
                Cancel
              </button>
            </div>
          </form>
          </div>
        </div>

        <div :if={@alerts == []} class="text-muted py-3">No alert rules configured.</div>
        <div :if={@alerts != []} class="card">
          <div class="card-body p-0">
        <table class="table table-sm table-hover mb-0">
          <thead>
            <tr>
              <th>Name</th>
              <th>Metric</th>
              <th>Condition</th>
              <th class="text-end">Threshold</th>
              <th>Webhook</th>
              <th class="text-center">State</th>
              <th class="text-center">Enabled</th>
              <th class="text-end">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={alert <- @alerts}>
              <td class="fw-semibold"><%= alert.name %></td>
              <td style="font-family: monospace; font-size: 0.78rem;"><%= alert.metric %></td>
              <td><%= alert.condition %></td>
              <td class="text-end"><%= format_number(alert.threshold) %></td>
              <td><%= alert.webhook_format || "generic" %></td>
              <td class="text-center">
                <% state = worst_alert_state(alert) %>
                <span class="badge rounded-pill" style={alert_state_style(state)}>
                  <%= state %>
                </span>
              </td>
              <td class="text-center">
                <button
                  phx-click="toggle_alert"
                  phx-value-id={alert.id}
                  type="button"
                  class={"btn btn-sm #{if(alert.enabled, do: "btn-success", else: "btn-outline-secondary")}"}
                >
                  <%= if alert.enabled, do: "on", else: "off" %>
                </button>
              </td>
              <td class="text-end text-nowrap">
                <button
                  phx-click="edit_alert"
                  phx-value-id={alert.id}
                  type="button"
                  class="btn btn-outline-primary btn-sm me-1"
                >
                  Edit
                </button>
                <button
                  phx-click="delete_alert"
                  phx-value-id={alert.id}
                  data-confirm="Delete this alert rule?"
                  type="button"
                  class="btn btn-outline-danger btn-sm"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
          </div>
        </div>

        <div class="mt-4">
          <div class="d-flex align-items-center justify-content-between mb-3">
            <h5 class="mb-0">Recent Activity</h5>
            <button
              :if={Enum.any?(@alert_history, & &1.acknowledged)}
              phx-click="clear_alert_history"
              data-confirm="Remove all acknowledged history entries?"
              type="button"
              class="btn btn-outline-secondary btn-sm"
            >
              Clear Acknowledged
            </button>
          </div>
          <div :if={@alert_history == []} class="text-muted py-3">No alert history yet.</div>
          <div :if={@alert_history != []} class="card">
            <div class="card-body p-0">
          <table class="table table-sm table-hover mb-0">
            <thead>
              <tr>
                <th>Time</th>
                <th>Alert Name</th>
                <th>Metric</th>
                <th>Series</th>
                <th class="text-center">State</th>
                <th class="text-end">Value</th>
                <th class="text-center">Ack'd</th>
                <th class="text-end">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @alert_history}>
                <td style="font-family: monospace; font-size: 0.72rem; white-space: nowrap;"><%= format_ts(entry.created_at) %></td>
                <td class="fw-semibold"><%= entry.rule_name %></td>
                <td style="font-family: monospace; font-size: 0.78rem;"><%= entry.metric %></td>
                <td style="font-family: monospace; font-size: 0.72rem;"><%= format_labels(entry.series_labels) %></td>
                <td class="text-center">
                  <span class="badge rounded-pill" style={alert_state_style(entry.state)}>
                    <%= entry.state %>
                  </span>
                </td>
                <td class="text-end" style="font-family: monospace; font-size: 0.78rem;">
                  <%= if entry.value, do: format_number(entry.value), else: "—" %>
                </td>
                <td class="text-center">
                  <%= if entry.acknowledged, do: "✓", else: "—" %>
                </td>
                <td class="text-end">
                  <button
                    :if={!entry.acknowledged}
                    phx-click="acknowledge_alert"
                    phx-value-id={entry.id}
                    type="button"
                    class="btn btn-outline-primary btn-sm"
                  >
                    Ack
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
            </div>
          </div>
        </div>
      </div>
      """
    end

    defp render_storage(assigns) do
      ~H"""
      <div :if={@info}>
        <div class="row">
          <div class="col-md-6 mb-3">
            <div class="card h-100">
              <div class="card-body">
                <h6 class="card-subtitle text-muted mb-3">Database</h6>
                <dl class="row mb-0" style="font-size: 0.9rem;">
                  <dt class="col-sm-3">Path</dt>
                  <dd class="col-sm-9" style="word-break: break-all;">{@info.db_path || "in-memory / unavailable"}</dd>
                  <dt class="col-sm-3">Storage</dt>
                  <dd class="col-sm-9">{format_bytes(info_value(@info, :storage_bytes, :storage_bytes, 0))}</dd>
                </dl>
              </div>
            </div>
          </div>

          <div class="col-md-6 mb-3">
            <div class="card h-100">
              <div class="card-body">
                <h6 class="card-subtitle text-muted mb-3">Maintenance</h6>
                <div class="d-flex flex-wrap" style="gap: 0.5rem;">
                  <button
                    phx-click="trigger_backup"
                    disabled={!is_nil(@backup_task)}
                    type="button"
                    class="btn btn-primary btn-sm"
                  >
                    <%= if @backup_task, do: "Creating backup…", else: "Create Backup" %>
                  </button>
                  <button
                    phx-click="flush_store"
                    disabled={!is_nil(@flush_task)}
                    type="button"
                    class="btn btn-outline-secondary btn-sm"
                  >
                    <%= if @flush_task, do: "Flushing…", else: "Flush to Disk" %>
                  </button>
                </div>
                <p class="text-muted small mb-0 mt-3">
                  Backups are stored at <code><%= backup_dir(@info) %></code>
                </p>
              </div>
            </div>
          </div>
        </div>

        <div :if={@backups != []} class="card">
          <div class="card-body p-0">
          <table class="table table-sm table-hover mb-0">
            <thead>
              <tr>
                <th>Timestamp</th>
                <th class="text-end">Files</th>
                <th class="text-end">Size</th>
                <th :if={@download_path} class="text-center">Download</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={backup <- @backups}>
                <td style="font-family: monospace;"><%= backup.name %></td>
                <td class="text-end"><%= backup.file_count %></td>
                <td class="text-end"><%= format_bytes(backup.total_bytes) %></td>
                <td :if={@download_path} class="text-center">
                  <a
                    href={"#{@download_path}/backups/#{backup.name}"}
                    download
                    target="_blank"
                    class="btn btn-outline-primary btn-sm"
                  >tar.gz</a>
                </td>
              </tr>
            </tbody>
          </table>
          </div>
        </div>
      </div>
      <div :if={!@info} class="text-center text-muted py-4">Store not available.</div>
      """
    end

    attr(:label, :string, required: true)
    attr(:value, :string, required: true)

    defp stat_card(assigns) do
      ~H"""
      <div class="col-sm-6 col-xl-3 mb-3">
        <div class="card h-100">
          <div class="card-body text-center">
            <h6 class="card-subtitle text-muted mb-1"><%= @label %></h6>
            <h4 class="mb-0"><%= @value %></h4>
          </div>
        </div>
      </div>
      """
    end

    # --- Data loading ---

    defp load_data(socket) do
      store = socket.assigns.store

      case safe_info(store) do
        nil ->
          assign(socket, info: nil, metrics_list: [], alerts: [], backups: [])

        info ->
          info = enrich_info(info, store)

          socket
          |> assign(info: info)
          |> load_tab_data()
      end
    end

    defp info_value(info, primary_key, fallback_key, default) do
      Map.get(info, primary_key, Map.get(info, fallback_key, default))
    end

    defp backup_dir(%{db_path: path}) when is_binary(path),
      do: Path.join(Path.dirname(path), "backups")

    defp backup_dir(_info), do: "priv/observability/backups"

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

      metric_changed? = selected != socket.assigns.selected_metric

      socket
      |> assign(
        metrics_list: metrics_list,
        selected_metric: selected,
        chart_series_filter:
          if(metric_changed?, do: nil, else: socket.assigns.chart_series_filter),
        chart_series_options:
          if(metric_changed?, do: [], else: socket.assigns.chart_series_options),
        chart_hash: if(metric_changed?, do: nil, else: socket.assigns.chart_hash)
      )
      |> update_metric_page()
      |> load_chart()
    end

    defp update_metric_page(socket) do
      view =
        metric_page(
          socket.assigns.metrics_list,
          socket.assigns.metric_search,
          socket.assigns.metric_page,
          socket.assigns.metric_page_size
        )

      assign(socket,
        metric_groups: view.groups,
        metric_filtered_total: view.total,
        metric_page: view.page,
        metric_page_count: view.page_count
      )
    end

    @doc false
    def metric_page(metrics, search, requested_page, page_size)
        when is_list(metrics) and is_integer(page_size) and page_size > 0 do
      filtered =
        case String.downcase(to_string(search)) do
          "" -> metrics
          needle -> Enum.filter(metrics, &String.contains?(String.downcase(&1), needle))
        end

      total = length(filtered)
      page_count = max(div(total + page_size - 1, page_size), 1)
      page = requested_page |> max(1) |> min(page_count)
      visible = Enum.slice(filtered, (page - 1) * page_size, page_size)

      %{
        groups: group_metrics_by_prefix(visible),
        total: total,
        page: page,
        page_count: page_count
      }
    end

    defp load_chart(socket) do
      store = socket.assigns.store
      metric = socket.assigns.selected_metric
      socket = load_metric_metadata(socket)

      if metric do
        range_seconds = Map.get(@time_ranges, socket.assigns.time_range, 3600)
        now = System.os_time(:second)
        from = now - range_seconds
        bucket_seconds = max(div(range_seconds, @target_buckets), 1)
        label_filter = selected_series_labels(socket)

        case TimelessMetrics.query_aggregate_multi(store, metric, label_filter,
               from: from,
               to: now,
               bucket: {bucket_seconds, :seconds},
               aggregate: :avg
             ) do
          {:ok, series} when series != [] ->
            ranked = rank_series(series)

            series_options =
              if socket.assigns.chart_series_filter do
                socket.assigns.chart_series_options
              else
                ranked |> Enum.take(@max_series_options) |> build_series_options()
              end

            series_total =
              if socket.assigns.chart_series_filter do
                socket.assigns.chart_series_total
              else
                length(ranked)
              end

            visible_series = Enum.take(ranked, socket.assigns.max_chart_series)
            data_extent = compute_data_extent(visible_series, range_seconds)

            chart_hash =
              :crypto.hash(
                :sha256,
                :erlang.term_to_binary({
                  metric,
                  socket.assigns.time_range,
                  socket.assigns.chart_series_filter,
                  socket.assigns.chart_width,
                  socket.assigns.chart_height,
                  visible_series
                })
              )

            socket =
              assign(socket,
                data_extent: data_extent,
                time_from: from,
                time_to: now,
                chart_series_options: series_options,
                chart_series_total: series_total
              )

            if chart_hash == socket.assigns.chart_hash && socket.assigns.chart_data_uri do
              socket
            else
              svg =
                TimelessMetrics.Chart.render(metric, visible_series,
                  width: socket.assigns.chart_width,
                  height: socket.assigns.chart_height,
                  theme: :auto,
                  x_domain: {from, now}
                )

              assign(socket,
                chart_data_uri: "data:image/svg+xml;base64," <> Base.encode64(svg),
                chart_hash: chart_hash
              )
            end

          _ ->
            assign(socket,
              chart_data_uri: nil,
              chart_hash: nil,
              chart_series_total:
                if(socket.assigns.chart_series_filter,
                  do: socket.assigns.chart_series_total,
                  else: 0
                ),
              data_extent: nil,
              time_from: from,
              time_to: now
            )
        end
      else
        assign(socket,
          chart_data_uri: nil,
          chart_hash: nil,
          chart_series_options: [],
          chart_series_total: 0,
          chart_series_filter: nil,
          metric_metadata: nil,
          metadata_metric: nil,
          data_extent: nil,
          time_from: nil,
          time_to: nil
        )
      end
    end

    defp load_metric_metadata(socket) do
      metric = socket.assigns.selected_metric

      if metric && socket.assigns.metadata_metric != metric do
        {:ok, metadata} = TimelessMetrics.get_metadata(socket.assigns.store, metric)

        assign(socket, metric_metadata: metadata, metadata_metric: metric)
      else
        socket
      end
    rescue
      _ ->
        assign(socket,
          metric_metadata: nil,
          metadata_metric: socket.assigns.selected_metric
        )
    catch
      :exit, _ ->
        assign(socket,
          metric_metadata: nil,
          metadata_metric: socket.assigns.selected_metric
        )
    end

    defp selected_series_labels(socket) do
      case socket.assigns.chart_series_filter do
        nil ->
          %{}

        selected ->
          socket.assigns.chart_series_options
          |> Enum.find(&(&1.key == selected))
          |> case do
            nil -> %{}
            option -> option.labels
          end
      end
    end

    @doc false
    def rank_series(series) do
      Enum.sort_by(series, &series_volume/1, :desc)
    end

    defp series_volume(%{data: data}) do
      Enum.reduce(data, 0, fn {_timestamp, value}, acc -> acc + abs(value) end)
    end

    defp build_series_options(series) do
      Enum.map(series, fn %{labels: labels} ->
        %{
          key:
            labels
            |> :erlang.term_to_binary()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.url_encode64(padding: false),
          label: series_label(labels),
          labels: labels
        }
      end)
    end

    defp series_label(labels) when map_size(labels) == 0, do: "(unlabeled)"

    defp series_label(labels) do
      labels
      |> Enum.sort()
      |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
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
            "Data covers #{format_duration_human(actual)} within selected #{format_duration_human(range_seconds)}"
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

    defp load_storage(socket, force \\ false) do
      now = System.monotonic_time(:millisecond)
      loaded_at = socket.assigns.storage_loaded_at
      fresh? = is_integer(loaded_at) && now - loaded_at < @storage_cache_ms

      if fresh? && !force do
        socket
      else
        assign(socket, backups: list_backups(socket.assigns.info), storage_loaded_at: now)
      end
    end

    @doc false
    def list_backups(%{db_path: db_path}) when is_binary(db_path) do
      backup_dir = Path.join(Path.dirname(db_path), "backups")

      case File.ls(backup_dir) do
        {:ok, names} ->
          names
          |> Enum.sort(:desc)
          |> Enum.take(20)
          |> Enum.flat_map(&backup_summary(backup_dir, &1))

        {:error, _reason} ->
          []
      end
    end

    def list_backups(_info), do: []

    defp backup_summary(backup_dir, name) do
      path = Path.join(backup_dir, name)

      case File.ls(path) do
        {:ok, files} ->
          total_bytes =
            Enum.reduce(files, 0, fn file, total ->
              case File.stat(Path.join(path, file)) do
                {:ok, %{size: size, type: :regular}} -> total + size
                _ -> total
              end
            end)

          [%{name: name, file_count: length(files), total_bytes: total_bytes}]

        {:error, _reason} ->
          []
      end
    end

    defp start_maintenance(socket, kind, fun) do
      parent = self()
      ref = make_ref()

      {:ok, pid} = Task.start(fn -> send(parent, {:maintenance_finished, kind, ref, fun.()}) end)
      monitor = Process.monitor(pid)
      assign(socket, [{task_assign(kind), %{ref: ref, monitor: monitor}}])
    end

    defp finish_maintenance(socket, :backup, {:ok, result}) do
      socket
      |> assign(backup_task: nil, storage_loaded_at: nil)
      |> set_flash(
        "Backup created: #{length(result.files)} files, #{format_bytes(result.total_bytes)}"
      )
      |> load_storage(true)
    end

    defp finish_maintenance(socket, :backup, {:error, reason}) do
      socket
      |> assign(backup_task: nil)
      |> set_flash("Backup failed: #{format_error(reason)}")
    end

    defp finish_maintenance(socket, :flush, :ok) do
      socket
      |> assign(flush_task: nil)
      |> set_flash("Store flushed")
      |> load_data()
    end

    defp finish_maintenance(socket, :flush, {:error, reason}) do
      socket
      |> assign(flush_task: nil)
      |> set_flash("Flush failed: #{format_error(reason)}")
    end

    defp task_assign(:backup), do: :backup_task
    defp task_assign(:flush), do: :flush_task

    defp maintenance_kind(socket, monitor) do
      Enum.find([:backup, :flush], fn kind ->
        case Map.get(socket.assigns, task_assign(kind)) do
          %{monitor: ^monitor} -> true
          _ -> false
        end
      end)
    end

    defp create_backup(_store, %{db_path: db_path}) when not is_binary(db_path),
      do: {:error, "store has no on-disk database path"}

    defp create_backup(store, %{db_path: db_path}) do
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S_%f")
      target = Path.join([Path.dirname(db_path), "backups", timestamp])
      TimelessMetrics.backup(store, target)
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end

    defp create_backup(_store, _info), do: {:error, "store is not available"}

    defp safe_flush(store) do
      case TimelessMetrics.flush(store) do
        :ok -> :ok
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_return, other}}
      end
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end

    defp maybe_expire_storage_cache(socket, :storage),
      do: assign(socket, storage_loaded_at: nil)

    defp maybe_expire_storage_cache(socket, _tab), do: socket

    defp set_flash(socket, msg) do
      cancel_timer(socket.assigns.flash_timer)
      token = make_ref()
      timer = Process.send_after(self(), {:clear_flash, token}, 5_000)
      assign(socket, flash_msg: msg, flash_timer: %{token: token, timer: timer})
    end

    defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)
    defp cancel_timer(_timer), do: false

    defp format_error(%{__exception__: true} = error), do: Exception.message(error)
    defp format_error(reason), do: inspect(reason)

    defp safe_info(store) do
      TimelessMetrics.info(store)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end

    # `:raw_ingested_bytes` is the honest raw side of the compression ratio:
    # 16 bytes per sample (8-byte timestamp + 8-byte value), the same figure
    # the timeless-metrics-api stats JSON serves. It derives from durable
    # point counts, so it is lifetime-accurate. Newer timeless_metrics
    # releases may surface it in `info/1` directly (`Map.put_new` keeps that
    # value); until then we derive it for libSQL stores, whose
    # `storage_bytes` is data-block payload only (`bytes_on_disk`). The
    # deprecated engines report whole-file bytes there — file, WAL,
    # freelist, and index bytes never belong inside a compression ratio —
    # so they keep the bytes-per-point fallback display instead.
    @doc false
    def enrich_info(info, store) do
      if libsql_store?(store) do
        Map.put_new(info, :raw_ingested_bytes, 16 * Map.get(info, :total_points, 0))
      else
        info
      end
    end

    # Mirrors TimelessMetrics.Supervisor, which records the engine here.
    defp libsql_store?(store) do
      :persistent_term.get({TimelessMetrics, store, :engine}, nil) == :libsql
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

    # The honest compression figure: raw bytes over stored data-block
    # bytes. Index, WAL, freelist, and whole-file bytes never appear here.
    defp format_compression_ratio(raw, stored)
         when is_number(raw) and raw > 0 and is_number(stored) and stored > 0 do
      ratio = raw / stored
      pct = Float.round((1 - stored / raw) * 100, 1)
      "#{Float.round(ratio, 1)}x (#{pct}% smaller)"
    end

    defp format_compression_ratio(_, _), do: "—"

    @doc false
    def format_compression_status(info) do
      raw = info_value(info, :raw_ingested_bytes, :raw_ingested_bytes, 0)
      stored = info_value(info, :storage_bytes, :storage_bytes, 0)
      disk_points = info_value(info, :disk_points, :disk_points, 0)
      bpp = info_value(info, :bytes_per_point, :bytes_per_point, 0.0)

      cond do
        is_number(raw) and raw > 0 and is_number(stored) and stored > 0 ->
          format_compression_ratio(raw, stored)

        disk_points > 0 and is_number(bpp) and bpp > 0 ->
          # Older stores without raw_ingested_bytes: 16 raw bytes per
          # point (8-byte timestamp + 8-byte value) against the
          # engine-reported stored bytes per point, unchanged from the
          # pre-raw-counter display.
          format_compression_ratio(16.0, bpp)

        info_value(info, :raw_buffer_points, :buffer_points, 0) > 0 ->
          "Buffered"

        true ->
          "—"
      end
    end

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
        "webhook_url" => "",
        "webhook_format" => "generic"
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

    defp safe_string(value, allowed, default) do
      if value in allowed, do: value, else: default
    end

    defp parse_tab("overview"), do: {:ok, :overview}
    defp parse_tab("metrics"), do: {:ok, :metrics}
    defp parse_tab("alerts"), do: {:ok, :alerts}
    defp parse_tab("storage"), do: {:ok, :storage}
    defp parse_tab(_tab), do: :error

    defp positive_integer_option(opts, key, default) do
      case Keyword.get(opts, key, default) do
        value when is_integer(value) and value > 0 -> value
        value -> raise ArgumentError, "#{inspect(key)} must be positive, got: #{inspect(value)}"
      end
    end
  end
end
