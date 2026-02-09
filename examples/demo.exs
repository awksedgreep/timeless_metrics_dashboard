# Minimal Phoenix app to test TimelessDashboard.
#
# Run:  mix run examples/demo.exs
# Open: http://localhost:4000/dashboard/timeless
# Stop: Ctrl+C twice

Logger.configure(level: :info)

# --- Phoenix Endpoint + Router ---

defmodule Demo.Router do
  use Phoenix.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  forward "/timeless/downloads", TimelessDashboard.DownloadPlug, store: :demo

  scope "/" do
    pipe_through :browser
    live_dashboard "/dashboard",
      additional_pages: [
        timeless: {TimelessDashboard.Page, store: :demo, download_path: "/timeless/downloads"}
      ]
  end
end

defmodule Demo.ErrorView do
  def render(template, _assigns), do: "Error: #{template}"
end

defmodule Demo.Endpoint do
  use Phoenix.Endpoint, otp_app: :timeless_dashboard

  @session_options [
    store: :cookie,
    key: "_demo_key",
    signing_salt: "demo_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug Demo.Router
end

# --- Boot everything ---

data_dir = System.get_env("TIMELESS_DATA_DIR") || Path.join(System.tmp_dir!(), "timeless_demo")
File.mkdir_p!(data_dir)
IO.puts("Data dir: #{data_dir}")

# Configure endpoint
Application.put_env(:timeless_dashboard, Demo.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4000],
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "demo_lv_salt"],
  pubsub_server: Demo.PubSub,
  server: true
)

# Start deps
{:ok, _} = Application.ensure_all_started(:phoenix_live_dashboard)

# Start PubSub (required by LiveView)
{:ok, _} = Supervisor.start_link(
  [{Phoenix.PubSub, name: Demo.PubSub}],
  strategy: :one_for_one
)

# Start Timeless store
{:ok, _} = Supervisor.start_link(
  [{Timeless, name: :demo, data_dir: data_dir}],
  strategy: :one_for_one
)

# Start TimelessDashboard reporter with VM metrics + Phoenix metrics
# telemetry_poller fires every 2s by default, reporter flushes every 5s
{:ok, _} = TimelessDashboard.Reporter.start_link(
  store: :demo,
  metrics:
    TimelessDashboard.DefaultMetrics.vm_metrics() ++
    TimelessDashboard.DefaultMetrics.phoenix_metrics() ++
    TimelessDashboard.DefaultMetrics.live_view_metrics() ++
    TimelessDashboard.DefaultMetrics.timeless_metrics(),
  flush_interval: 5_000,
  name: :demo_reporter
)

# Start endpoint
{:ok, _} = Demo.Endpoint.start_link()

IO.puts("""

========================================
  TimelessDashboard Demo
  http://localhost:4000/dashboard/timeless
========================================
""")

# Keep the script alive
Process.sleep(:infinity)
