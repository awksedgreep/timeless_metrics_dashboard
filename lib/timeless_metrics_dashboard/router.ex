defmodule TimelessMetricsDashboard.Router do
  @moduledoc """
  Router macro for one-line LiveDashboard setup with TimelessMetrics pages.

  ## Usage

      defmodule MyAppWeb.Router do
        use Phoenix.Router
        import TimelessMetricsDashboard.Router

        scope "/" do
          pipe_through :browser
          timeless_metrics_dashboard "/dashboard"
        end
      end

  ## Options

    * `:name` — TimelessMetrics store name (default: `:timeless_metrics`)
    * `:metrics` — metrics module passed to LiveDashboard (default: `TimelessMetricsDashboard.DefaultMetrics`)
    * `:download_path` — path for backup downloads (default: `"/timeless/downloads"`)
    * `:live_dashboard` — extra opts merged into `live_dashboard` call
  """

  @doc """
  Mounts the TimelessMetricsDashboard download plug and LiveDashboard with metrics pages.
  """
  defmacro timeless_metrics_dashboard(path, opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      import Phoenix.LiveDashboard.Router

      store = Keyword.get(opts, :name, :timeless_metrics)
      metrics_mod = Keyword.get(opts, :metrics, TimelessMetricsDashboard.DefaultMetrics)
      download_path = Keyword.get(opts, :download_path, "/timeless/downloads")
      extra = Keyword.get(opts, :live_dashboard, [])

      forward download_path, TimelessMetricsDashboard.DownloadPlug, store: store

      dashboard_opts =
        [
          live_session_name: :timeless_metrics_dashboard,
          metrics: metrics_mod,
          metrics_history: {TimelessMetricsDashboard, :metrics_history, [store]},
          additional_pages: [
            timeless: {TimelessMetricsDashboard.Page, store: store, download_path: download_path}
          ]
        ] ++ extra

      live_dashboard path, dashboard_opts
    end
  end
end
