defmodule TimelessMetricsDashboard.PageTest do
  use ExUnit.Case, async: false

  alias TimelessMetricsDashboard.Page

  @store :page_test_store

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "timeless_page_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)

    start_supervised!({TimelessMetrics, name: @store, data_dir: data_dir})

    on_exit(fn ->
      File.rm_rf!(data_dir)
    end)

    %{data_dir: data_dir}
  end

  describe "init/1" do
    test "returns session with store" do
      assert {:ok, session} = Page.init(store: @store)
      assert session.store == @store
    end

    test "accepts chart dimensions" do
      assert {:ok, session} = Page.init(store: @store, chart_width: 900, chart_height: 400)
      assert session.chart_width == 900
      assert session.chart_height == 400
    end

    test "uses default chart dimensions" do
      assert {:ok, session} = Page.init(store: @store)
      assert session.chart_width == 700
      assert session.chart_height == 250
    end
  end

  describe "menu_link/2" do
    test "shows series count when store is running" do
      {:ok, session} = Page.init(store: @store)
      assert {:ok, text} = Page.menu_link(session, %{})
      assert text =~ "Timeless"
      assert text =~ "(0)"
    end

    test "returns disabled when store not running" do
      {:ok, session} = Page.init(store: :nonexistent_store)
      assert {:disabled, "TimelessMetrics", "Store not running"} = Page.menu_link(session, %{})
    end

    test "shows correct count after writing data" do
      TimelessMetrics.write(@store, "test.metric", %{"host" => "a"}, 42.0)
      TimelessMetrics.flush(@store)

      {:ok, session} = Page.init(store: @store)
      {:ok, text} = Page.menu_link(session, %{})
      assert text =~ "(1)"
    end
  end

  describe "format_compression_status/1" do
    test "shows the honest ratio when raw_ingested_bytes is present" do
      info = %{
        raw_ingested_bytes: 16_000_000,
        storage_bytes: 2_000_000,
        disk_points: 1_000_000,
        bytes_per_point: 2.0
      }

      assert Page.format_compression_status(info) == "8.0x (87.5% smaller)"
    end

    test "falls back to the bytes-per-point display when raw_ingested_bytes is absent" do
      info = %{disk_points: 1_000, bytes_per_point: 4.0}

      assert Page.format_compression_status(info) == "4.0x (75.0% smaller)"
    end

    test "falls back to the bytes-per-point display when raw_ingested_bytes is zero" do
      info = %{raw_ingested_bytes: 0, storage_bytes: 0, disk_points: 1_000, bytes_per_point: 4.0}

      assert Page.format_compression_status(info) == "4.0x (75.0% smaller)"
    end

    test "shows Buffered when nothing is on disk yet" do
      info = %{raw_ingested_bytes: 160, storage_bytes: 0, raw_buffer_points: 10}

      assert Page.format_compression_status(info) == "Buffered"
    end

    test "shows a dash for an empty store" do
      assert Page.format_compression_status(%{}) == "—"
    end
  end

  describe "enrich_info/2" do
    test "derives raw_ingested_bytes as 16 bytes per point for a libsql store" do
      enriched = Page.enrich_info(%{total_points: 3}, @store)

      assert enriched.raw_ingested_bytes == 48
    end

    test "keeps a raw_ingested_bytes already provided by the store" do
      enriched = Page.enrich_info(%{total_points: 3, raw_ingested_bytes: 160}, @store)

      assert enriched.raw_ingested_bytes == 160
    end

    test "does not derive raw_ingested_bytes for non-libsql stores" do
      enriched = Page.enrich_info(%{total_points: 3}, :not_a_running_store)

      refute Map.has_key?(enriched, :raw_ingested_bytes)
    end

    test "enriched live store info renders the honest ratio" do
      TimelessMetrics.write(@store, "test.metric", %{"host" => "a"}, 42.0)
      TimelessMetrics.flush(@store)

      info = @store |> TimelessMetrics.info() |> Page.enrich_info(@store)

      assert info.raw_ingested_bytes == 16 * info.total_points
      assert info.raw_ingested_bytes > 0

      rendered = Page.format_compression_status(info)
      assert rendered =~ ~r/^\d+(\.\d+)?x \(-?\d+(\.\d+)?% smaller\)$/
    end
  end
end
