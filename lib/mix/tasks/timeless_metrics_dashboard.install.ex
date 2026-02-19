if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.TimelessMetricsDashboard.Install do
    @shortdoc "Installs TimelessMetricsDashboard into your application."
    @moduledoc """
    #{@shortdoc}

    Adds TimelessMetricsDashboard to your supervision tree (starts TimelessMetrics +
    telemetry reporter), configures your Phoenix router with the metrics dashboard page,
    and updates the formatter.

    ## Usage

        mix igniter.install timeless_metrics_dashboard

    ## What it does

    1. Adds `{TimelessMetricsDashboard, data_dir: "priv/timeless_metrics"}` to your
       application's supervision tree
    2. Adds `import TimelessMetricsDashboard.Router` to your Phoenix router
    3. Adds `timeless_metrics_dashboard "/dashboard"` to your router's browser scope
    4. Adds `:timeless_metrics_dashboard` to your `.formatter.exs` import_deps
    5. Reminds you to remove the default LiveDashboard route (avoids live_session conflict)
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :timeless_metrics_dashboard,
        schema: [],
        defaults: [],
        required: [],
        positional: [],
        aliases: [],
        composes: [],
        installs: [],
        adds_deps: [],
        example: "mix igniter.install timeless_metrics_dashboard"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> add_to_supervision_tree()
      |> setup_router()
      |> Igniter.Project.Formatter.import_dep(:timeless_metrics_dashboard)
      |> add_live_dashboard_notice()
    end

    defp add_to_supervision_tree(igniter) do
      child_code =
        Sourceror.parse_string!(~s([data_dir: "priv/timeless_metrics"]))

      Igniter.Project.Application.add_new_child(
        igniter,
        {TimelessMetricsDashboard, {:code, child_code}}
      )
    end

    defp setup_router(igniter) do
      case Igniter.Libs.Phoenix.select_router(igniter) do
        {igniter, nil} ->
          Igniter.add_warning(igniter, """
          No Phoenix router found. Add the following manually:

              import TimelessMetricsDashboard.Router

              scope "/" do
                pipe_through :browser
                timeless_metrics_dashboard "/dashboard"
              end
          """)

        {igniter, router} ->
          igniter
          |> add_router_import(router)
          |> Igniter.Libs.Phoenix.append_to_scope(
            "/",
            """
            timeless_metrics_dashboard "/dashboard"
            """,
            with_pipelines: [:browser],
            router: router
          )
      end
    end

    defp add_router_import(igniter, router) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case Igniter.Libs.Phoenix.move_to_router_use(igniter, zipper) do
          {:ok, zipper} ->
            {:ok, Igniter.Code.Common.add_code(zipper, "import TimelessMetricsDashboard.Router")}

          _ ->
            {:ok, zipper}
        end
      end)
    end

    defp add_live_dashboard_notice(igniter) do
      Igniter.add_notice(igniter, """
      TimelessMetricsDashboard installs its own LiveDashboard at /dashboard.

      If your router has a default LiveDashboard route (typically in a
      `if Application.compile_env(:your_app, :dev_routes)` block), you should
      remove it to avoid a live_session conflict.
      """)
    end
  end
else
  defmodule Mix.Tasks.TimelessMetricsDashboard.Install do
    @shortdoc "Installs TimelessMetricsDashboard (requires igniter)."
    @moduledoc @shortdoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'timeless_metrics_dashboard.install' requires igniter.
      Please install igniter and try again.

          {:igniter, "~> 0.6", only: [:dev]}

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
