defmodule TimelessMetricsDashboard.ReporterTest do
  use ExUnit.Case, async: false

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
               h.id == {TimelessMetricsDashboard.Reporter, "telemetry", [:test, :lifecycle]}
             end)
    end
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
    test "captures all metrics for a single event" do
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
      # Both summary and counter produce the same metric name but are separate writes
      assert "telemetry.test.multi.duration" in metrics_list
    end
  end
end
