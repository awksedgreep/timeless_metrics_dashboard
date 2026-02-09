defmodule TimelessDashboard.DefaultMetricsTest do
  use ExUnit.Case, async: true

  alias TimelessDashboard.DefaultMetrics

  describe "vm_metrics/0" do
    test "returns non-empty list of valid metrics" do
      metrics = DefaultMetrics.vm_metrics()
      assert is_list(metrics)
      assert length(metrics) > 0

      Enum.each(metrics, fn metric ->
        assert %{__struct__: struct} = metric
        assert struct in [
                 Telemetry.Metrics.Counter,
                 Telemetry.Metrics.Sum,
                 Telemetry.Metrics.LastValue,
                 Telemetry.Metrics.Summary,
                 Telemetry.Metrics.Distribution
               ]
      end)
    end

    test "all vm metrics are last_value type" do
      metrics = DefaultMetrics.vm_metrics()

      Enum.each(metrics, fn metric ->
        assert %Telemetry.Metrics.LastValue{} = metric
      end)
    end
  end

  describe "phoenix_metrics/0" do
    test "returns non-empty list of valid metrics" do
      metrics = DefaultMetrics.phoenix_metrics()
      assert is_list(metrics)
      assert length(metrics) > 0

      Enum.each(metrics, fn metric ->
        assert %{__struct__: struct} = metric
        assert struct in [
                 Telemetry.Metrics.Counter,
                 Telemetry.Metrics.Summary
               ]
      end)
    end
  end

  describe "ecto_metrics/1" do
    test "accepts repo prefix parameter" do
      metrics = DefaultMetrics.ecto_metrics("my_app.repo")
      assert is_list(metrics)
      assert length(metrics) > 0

      # Verify event names use the prefix
      Enum.each(metrics, fn metric ->
        assert hd(metric.event_name) == :my_app
      end)
    end

    test "works with different repo prefixes" do
      metrics = DefaultMetrics.ecto_metrics("other_app.different_repo")
      assert length(metrics) > 0

      Enum.each(metrics, fn metric ->
        assert hd(metric.event_name) == :other_app
      end)
    end
  end

  describe "live_view_metrics/0" do
    test "returns non-empty list of valid metrics" do
      metrics = DefaultMetrics.live_view_metrics()
      assert is_list(metrics)
      assert length(metrics) > 0

      Enum.each(metrics, fn metric ->
        assert %Telemetry.Metrics.Summary{} = metric
      end)
    end

    test "includes handle_params and live_component events" do
      metrics = DefaultMetrics.live_view_metrics()
      names = Enum.map(metrics, fn m -> Enum.join(m.name, ".") end)
      assert Enum.any?(names, &String.contains?(&1, "handle_params"))
      assert Enum.any?(names, &String.contains?(&1, "live_component"))
    end
  end

  describe "timeless_metrics/0" do
    test "returns non-empty list of valid metrics" do
      metrics = DefaultMetrics.timeless_metrics()
      assert is_list(metrics)
      assert length(metrics) > 0

      Enum.each(metrics, fn metric ->
        assert %{__struct__: struct} = metric
        assert struct in [
                 Telemetry.Metrics.Counter,
                 Telemetry.Metrics.Summary
               ]
      end)
    end

    test "covers buffer, segment, query, rollup, http, and backpressure" do
      metrics = DefaultMetrics.timeless_metrics()
      names = Enum.map(metrics, fn m -> Enum.join(m.name, ".") end)

      assert Enum.any?(names, &String.starts_with?(&1, "timeless.buffer"))
      assert Enum.any?(names, &String.starts_with?(&1, "timeless.segment"))
      assert Enum.any?(names, &String.starts_with?(&1, "timeless.query"))
      assert Enum.any?(names, &String.starts_with?(&1, "timeless.rollup"))
      assert Enum.any?(names, &String.starts_with?(&1, "timeless.http"))
      assert Enum.any?(names, &String.starts_with?(&1, "timeless.write"))
    end
  end
end
