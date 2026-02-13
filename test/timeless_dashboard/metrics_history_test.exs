defmodule TimelessDashboard.MetricsHistoryTest do
  use ExUnit.Case, async: false

  import Telemetry.Metrics

  @store :metrics_history_test_store

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "timeless_mh_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)

    start_supervised!({TimelessMetrics, name: @store, data_dir: data_dir})

    on_exit(fn ->
      File.rm_rf!(data_dir)
    end)

    %{data_dir: data_dir}
  end

  defp write_and_flush(metric_name, labels, value, timestamp) do
    TimelessMetrics.write(@store, metric_name, labels, value, timestamp: timestamp)
    TimelessMetrics.flush(@store)
  end

  describe "chronological ordering" do
    test "returns points sorted by time when multiple series share a label" do
      now = System.os_time(:second)

      # Write points to two series with different labels — both will collapse
      # to the same LiveDashboard label when the metric has no tags
      write_and_flush("telemetry.test.query.duration", %{"source" => "users"}, 10.0, now - 3)
      write_and_flush("telemetry.test.query.duration", %{"source" => "users"}, 20.0, now - 1)
      write_and_flush("telemetry.test.query.duration", %{"source" => "posts"}, 15.0, now - 2)

      # Metric with no tags — all series collapse to label: nil
      metric = summary("test.query.duration")
      result = TimelessDashboard.metrics_history(metric, @store)

      times = Enum.map(result, & &1.time)
      assert times == Enum.sort(times), "Points must be sorted chronologically"
    end

    test "returns points sorted by time with a single series" do
      now = System.os_time(:second)

      write_and_flush("telemetry.test.single.value", %{}, 1.0, now - 3)
      write_and_flush("telemetry.test.single.value", %{}, 2.0, now - 2)
      write_and_flush("telemetry.test.single.value", %{}, 3.0, now - 1)

      metric = summary("test.single.value")
      result = TimelessDashboard.metrics_history(metric, @store)

      times = Enum.map(result, & &1.time)
      assert times == Enum.sort(times)
      assert length(result) == 3
    end
  end

  describe "overlapping timestamp averaging" do
    test "averages values at the same timestamp when series share a label" do
      now = System.os_time(:second)

      # Two series, same timestamp, different values — no tags means same label
      write_and_flush("telemetry.test.overlap.value", %{"source" => "a"}, 100.0, now)
      write_and_flush("telemetry.test.overlap.value", %{"source" => "b"}, 200.0, now)

      metric = summary("test.overlap.value")
      result = TimelessDashboard.metrics_history(metric, @store)

      # Should produce one point (averaged), not two
      assert length(result) == 1
      [point] = result
      assert_in_delta point.measurement, 150.0, 0.01
      assert point.time == now * 1_000_000
    end

    test "does not average across different labels" do
      now = System.os_time(:second)

      write_and_flush("telemetry.test.tagged.value", %{"method" => "GET"}, 100.0, now)
      write_and_flush("telemetry.test.tagged.value", %{"method" => "POST"}, 200.0, now)

      # Metric WITH tags — each series keeps its own label
      metric = summary("test.tagged.value", tags: [:method], tag_values: & &1)
      result = TimelessDashboard.metrics_history(metric, @store)

      # Should produce two separate points with different labels
      assert length(result) == 2
      labels = Enum.map(result, & &1.label) |> Enum.sort()
      assert labels == ["GET", "POST"]
    end

    test "averages multiple overlapping timestamps correctly" do
      now = System.os_time(:second)

      # 3 series, 2 timestamps each — all collapse to nil label
      for {source, vals} <- [{"x", [10, 40]}, {"y", [20, 50]}, {"z", [30, 60]}] do
        write_and_flush("telemetry.test.multi.overlap", %{"source" => source}, vals |> hd() |> (& &1 * 1.0).(), now - 1)
        write_and_flush("telemetry.test.multi.overlap", %{"source" => source}, vals |> List.last() |> (& &1 * 1.0).(), now)
      end

      metric = summary("test.multi.overlap")
      result = TimelessDashboard.metrics_history(metric, @store)

      assert length(result) == 2

      [earlier, later] = Enum.sort_by(result, & &1.time)
      # (10 + 20 + 30) / 3 = 20.0
      assert_in_delta earlier.measurement, 20.0, 0.01
      # (40 + 50 + 60) / 3 = 50.0
      assert_in_delta later.measurement, 50.0, 0.01
    end
  end

  describe "time format" do
    test "returns time in microseconds" do
      now = System.os_time(:second)
      write_and_flush("telemetry.test.time.format", %{}, 1.0, now)

      metric = summary("test.time.format")
      [point] = TimelessDashboard.metrics_history(metric, @store)

      assert point.time == now * 1_000_000
    end
  end

  describe "empty data" do
    test "returns empty list when no data exists" do
      metric = summary("test.nonexistent.metric")
      assert TimelessDashboard.metrics_history(metric, @store) == []
    end
  end
end
