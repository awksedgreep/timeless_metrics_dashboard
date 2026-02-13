defmodule TimelessDashboard.PageTest do
  use ExUnit.Case, async: false

  alias TimelessDashboard.Page

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
      assert {:disabled, "Timeless", "Store not running"} = Page.menu_link(session, %{})
    end

    test "shows correct count after writing data" do
      TimelessMetrics.write(@store, "test.metric", %{"host" => "a"}, 42.0)
      TimelessMetrics.flush(@store)

      {:ok, session} = Page.init(store: @store)
      {:ok, text} = Page.menu_link(session, %{})
      assert text =~ "(1)"
    end
  end
end
