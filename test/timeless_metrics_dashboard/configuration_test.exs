defmodule TimelessMetricsDashboard.ConfigurationTest do
  use ExUnit.Case, async: false

  test "reporter-specific store and metrics options override supervisor defaults" do
    assert {:ok, {_flags, [_store_child, reporter_child]}} =
             TimelessMetricsDashboard.Supervisor.init(
               name: :default_store,
               metrics: [:default_metrics],
               reporter: [store: :reporter_store, metrics: [:reporter_metrics], batch_size: 7]
             )

    assert {TimelessMetricsDashboard.Reporter, :start_link, [opts]} = reporter_child.start
    assert opts[:store] == :reporter_store
    assert opts[:metrics] == [:reporter_metrics]
    assert opts[:batch_size] == 7
    assert Keyword.keys(opts) |> Enum.count(&(&1 == :store)) == 1
    assert Keyword.keys(opts) |> Enum.count(&(&1 == :metrics)) == 1
  end

  test "two router mounts can use distinct live session names" do
    source = """
    defmodule TimelessMetricsDashboard.MultiMountRouterFixture do
      use Phoenix.Router
      import TimelessMetricsDashboard.Router

      scope "/" do
        timeless_metrics_dashboard "/one",
          name: :one,
          download_path: "/downloads-one",
          live_session_name: :timeless_one

        timeless_metrics_dashboard "/two",
          name: :two,
          download_path: "/downloads-two",
          live_session_name: :timeless_two
      end
    end
    """

    modules = Code.compile_string(source)

    assert Enum.any?(modules, fn {module, _binary} ->
             module == TimelessMetricsDashboard.MultiMountRouterFixture
           end)
  end

  test "reporter-only sources compile without Phoenix or Plug on the code path" do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "timeless_reporter_compile_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(output_dir)
    on_exit(fn -> File.rm_rf!(output_dir) end)

    dependency_paths =
      for app <- [:telemetry, :telemetry_metrics, :timeless_metrics] do
        Application.app_dir(app, "ebin")
      end

    source_files = Path.wildcard("lib/**/*.ex") |> Enum.sort()

    args =
      Enum.flat_map(dependency_paths, &["-pa", &1]) ++
        ["-o", output_dir] ++ source_files

    {output, status} =
      System.cmd(System.find_executable("elixirc"), args,
        env: [{"ERL_LIBS", ""}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert File.exists?(Path.join(output_dir, "Elixir.TimelessMetricsDashboard.Reporter.beam"))
    refute File.exists?(Path.join(output_dir, "Elixir.TimelessMetricsDashboard.Page.beam"))
  end
end
