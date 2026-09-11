defmodule TimelessMetricsDashboard.ReporterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Telemetry.Metrics

  @store :reporter_test_store

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "timeless_reporter_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)

    start_supervised!({TimelessMetrics, name: @store, data_dir: data_dir})

    on_exit(fn ->
      File.rm_rf!(data_dir)
    end)

    %{data_dir: data_dir}
  end

  describe "basic event capture" do
    test "captures telemetry events and writes to store" do
      metrics = [
        last_value("test.request.duration", unit: {:native, :millisecond})
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_basic}
      )

      :telemetry.execute(
        [:test, :request],
        %{duration: System.convert_time_unit(42, :millisecond, :native)},
        %{}
      )

      TimelessMetricsDashboard.Reporter.flush(:reporter_basic)
      TimelessMetrics.flush(@store)

      {:ok, metrics_list} = TimelessMetrics.list_metrics(@store)
      assert "telemetry.test.request.duration" in metrics_list
    end

    test "extracts tags as labels" do
      metrics = [
        counter("test.tagged.count",
          event_name: [:test, :tagged],
          tags: [:method, :status],
          tag_values: fn meta -> meta end
        )
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_tags}
      )

      :telemetry.execute([:test, :tagged], %{count: 1}, %{method: "GET", status: 200})
      TimelessMetricsDashboard.Reporter.flush(:reporter_tags)
      TimelessMetrics.flush(@store)

      {:ok, series} = TimelessMetrics.list_series(@store, "telemetry.test.tagged.count")
      assert length(series) == 1
      labels = hd(series).labels
      assert labels["method"] == "GET"
      assert labels["status"] == "200"
    end
  end

  describe "filtering" do
    test "respects keep filter" do
      metrics = [
        counter("test.filtered.count",
          event_name: [:test, :filtered],
          keep: fn meta -> meta[:keep] == true end
        )
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_filter}
      )

      :telemetry.execute([:test, :filtered], %{count: 1}, %{keep: false})
      :telemetry.execute([:test, :filtered], %{count: 1}, %{keep: true})
      TimelessMetricsDashboard.Reporter.flush(:reporter_filter)
      TimelessMetrics.flush(@store)

      {:ok, results} = TimelessMetrics.query(@store, "telemetry.test.filtered.count", %{})
      assert length(results) == 1
    end
  end

  describe "unit conversion" do
    test "converts native to millisecond" do
      metrics = [
        last_value("test.convert.duration", unit: {:native, :millisecond})
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_convert}
      )

      native_100ms = System.convert_time_unit(100, :millisecond, :native)
      :telemetry.execute([:test, :convert], %{duration: native_100ms}, %{})
      TimelessMetricsDashboard.Reporter.flush(:reporter_convert)
      TimelessMetrics.flush(@store)

      {:ok, points} = TimelessMetrics.query(@store, "telemetry.test.convert.duration", %{})
      assert length(points) == 1
      [{_ts, value}] = points
      # Should be ~100ms (allow for rounding)
      assert_in_delta value, 100.0, 1.0
    end
  end

  describe "metadata registration" do
    test "registers metric metadata on init" do
      metrics = [
        last_value("test.meta.gauge",
          description: "A test gauge"
        )
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_meta}
      )

      {:ok, metadata} = TimelessMetrics.get_metadata(@store, "telemetry.test.meta.gauge")
      assert metadata.type == :gauge
      assert metadata.description == "A test gauge"
    end
  end

  describe "handler lifecycle" do
    test "detaches handlers on terminate" do
      metrics = [
        counter("test.lifecycle.count", event_name: [:test, :lifecycle])
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_lifecycle}
      )

      # Handler should be attached
      handlers = :telemetry.list_handlers([:test, :lifecycle])
      assert length(handlers) > 0

      stop_supervised!({TimelessMetricsDashboard.Reporter, :reporter_lifecycle})

      # Handler should be detached
      handlers = :telemetry.list_handlers([:test, :lifecycle])

      refute Enum.any?(handlers, fn h ->
               h.id ==
                 {TimelessMetricsDashboard.Reporter, :reporter_lifecycle, "telemetry",
                  [:test, :lifecycle]}
             end)
    end

    test "a stale handler cannot crash its telemetry emitter and restart captures again" do
      event = [:test, :reporter_restart]
      metrics = [counter("test.reporter_restart.count", event_name: event)]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_restart}
      )

      old_pid = Process.whereis(:reporter_restart)

      old_config =
        event
        |> :telemetry.list_handlers()
        |> Enum.find(
          &(&1.id ==
              {TimelessMetricsDashboard.Reporter, :reporter_restart, "telemetry", event})
        )
        |> Map.fetch!(:config)

      Process.exit(old_pid, :kill)
      assert_eventually(fn -> Process.whereis(:reporter_restart) not in [nil, old_pid] end)

      assert :ok =
               TimelessMetricsDashboard.Reporter.handle_event(event, %{count: 1}, %{}, old_config)

      :telemetry.execute(event, %{count: 1}, %{})
      TimelessMetricsDashboard.Reporter.flush(:reporter_restart)

      {:ok, points} =
        TimelessMetrics.query(@store, "telemetry.test.reporter_restart.count", %{})

      assert length(points) == 1
    end
  end

  describe "bounded, reliable draining" do
    test "concurrent flushes never delete points emitted during a drain" do
      event = [:test, :concurrent_flush]

      metrics = [
        counter("test.concurrent_flush.count",
          event_name: event,
          tags: [:id],
          tag_values: & &1
        )
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store,
         metrics: metrics,
         flush_interval: 0,
         max_buffer_size: 2_000,
         batch_size: 7,
         name: :reporter_concurrent}
      )

      flusher =
        Task.async(fn ->
          for _ <- 1..30, do: TimelessMetricsDashboard.Reporter.flush(:reporter_concurrent)
        end)

      1..500
      |> Task.async_stream(
        fn id -> :telemetry.execute(event, %{count: 1}, %{id: id}) end,
        max_concurrency: 20,
        timeout: 10_000
      )
      |> Stream.run()

      Task.await(flusher, 10_000)
      TimelessMetricsDashboard.Reporter.flush(:reporter_concurrent)
      TimelessMetrics.flush(@store)

      {:ok, series} =
        TimelessMetrics.list_series(@store, "telemetry.test.concurrent_flush.count")

      assert length(series) == 500
      assert TimelessMetricsDashboard.Reporter.stats(:reporter_concurrent).dropped == 0
    end

    test "caps the buffer and counts newest-point drops" do
      event = [:test, :bounded_buffer]

      metrics = [
        counter("test.bounded_buffer.count",
          event_name: event,
          tags: [:id],
          tag_values: & &1
        )
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store,
         metrics: metrics,
         flush_interval: 0,
         max_buffer_size: 10,
         name: :reporter_bounded}
      )

      for id <- 1..25, do: :telemetry.execute(event, %{count: 1}, %{id: id})

      assert %{buffered: 10, dropped: 15} =
               TimelessMetricsDashboard.Reporter.stats(:reporter_bounded)

      TimelessMetricsDashboard.Reporter.flush(:reporter_bounded)
      TimelessMetrics.flush(@store)

      {:ok, series} = TimelessMetrics.list_series(@store, "telemetry.test.bounded_buffer.count")
      assert length(series) == 10
    end

    test "retains a batch when the store is unavailable and writes it after recovery", %{
      data_dir: data_dir
    } do
      event = [:test, :store_recovery]
      metrics = [counter("test.store_recovery.count", event_name: event)]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_recovery}
      )

      stop_supervised!({TimelessMetrics, @store})
      :telemetry.execute(event, %{count: 1}, %{})

      log =
        capture_log(fn ->
          TimelessMetricsDashboard.Reporter.flush(:reporter_recovery)
        end)

      assert log =~ "Reporter flush failed"

      assert %{buffered: 1, write_errors: 1} =
               TimelessMetricsDashboard.Reporter.stats(:reporter_recovery)

      start_supervised!({TimelessMetrics, name: @store, data_dir: data_dir})
      TimelessMetricsDashboard.Reporter.flush(:reporter_recovery)
      TimelessMetrics.flush(@store)

      assert %{buffered: 0} = TimelessMetricsDashboard.Reporter.stats(:reporter_recovery)

      assert {:ok, [_point]} =
               TimelessMetrics.query(@store, "telemetry.test.store_recovery.count", %{})
    end
  end

  test "isolates raising metric callbacks from the emitter and other metrics" do
    event = [:test, :callback_error]

    metrics = [
      counter("test.callback_error.bad",
        event_name: event,
        keep: fn _ -> raise "bad callback" end
      ),
      counter("test.callback_error.good", event_name: event)
    ]

    start_supervised!(
      {TimelessMetricsDashboard.Reporter,
       store: @store, metrics: metrics, flush_interval: 0, name: :reporter_callback_error}
    )

    assert :ok = :telemetry.execute(event, %{bad: 1, good: 1}, %{})
    TimelessMetricsDashboard.Reporter.flush(:reporter_callback_error)

    assert %{callback_errors: 1} =
             TimelessMetricsDashboard.Reporter.stats(:reporter_callback_error)

    assert {:ok, [_point]} =
             TimelessMetrics.query(@store, "telemetry.test.callback_error.good", %{})
  end

  test "default router metrics use an unknown route instead of a raw request path" do
    start_supervised!(
      {TimelessMetricsDashboard.Reporter,
       store: @store,
       metrics: TimelessMetricsDashboard.DefaultMetrics.phoenix_metrics(),
       flush_interval: 0,
       name: :reporter_routes}
    )

    conn = %{method: "GET", status: 200, request_path: "/users/123456"}
    :telemetry.execute([:phoenix, :router_dispatch, :stop], %{duration: 42}, %{conn: conn})
    TimelessMetricsDashboard.Reporter.flush(:reporter_routes)

    {:ok, [%{labels: labels}]} =
      TimelessMetrics.list_series(@store, "telemetry.phoenix.router_dispatch.stop.duration")

    assert labels["route"] == "unknown"
    refute labels["route"] == conn.request_path

    assert {:ok, [{_timestamp, 1.0}]} =
             TimelessMetrics.query(
               @store,
               "telemetry.phoenix.router_dispatch.stop.count",
               labels
             )
  end

  describe "custom prefix" do
    test "uses custom prefix in metric names" do
      metrics = [
        counter("test.prefix.count", event_name: [:test, :prefix])
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store,
         metrics: metrics,
         flush_interval: 0,
         prefix: "custom",
         name: :reporter_prefix}
      )

      :telemetry.execute([:test, :prefix], %{count: 1}, %{})
      TimelessMetricsDashboard.Reporter.flush(:reporter_prefix)
      TimelessMetrics.flush(@store)

      {:ok, metrics_list} = TimelessMetrics.list_metrics(@store)
      assert "custom.test.prefix.count" in metrics_list
      refute "telemetry.test.prefix.count" in metrics_list
    end
  end

  describe "multiple metrics on same event" do
    test "deduplicates output names and registers metadata deterministically" do
      metrics = [
        summary("test.multi.duration", event_name: [:test, :multi]),
        counter("test.multi.duration", event_name: [:test, :multi])
      ]

      start_supervised!(
        {TimelessMetricsDashboard.Reporter,
         store: @store, metrics: metrics, flush_interval: 0, name: :reporter_multi}
      )

      :telemetry.execute([:test, :multi], %{duration: 42}, %{})
      TimelessMetricsDashboard.Reporter.flush(:reporter_multi)
      TimelessMetrics.flush(@store)

      {:ok, metrics_list} = TimelessMetrics.list_metrics(@store)
      assert "telemetry.test.multi.duration" in metrics_list

      {:ok, metadata} = TimelessMetrics.get_metadata(@store, "telemetry.test.multi.duration")
      assert metadata.type == :gauge

      {:ok, points} = TimelessMetrics.query(@store, "telemetry.test.multi.duration", %{})
      assert length(points) == 1
    end
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
