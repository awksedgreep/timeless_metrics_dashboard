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

    test "accepts scale limits" do
      assert {:ok, session} =
               Page.init(store: @store, metric_page_size: 50, max_chart_series: 5)

      assert session.metric_page_size == 50
      assert session.max_chart_series == 5
    end
  end

  describe "event validation" do
    test "ignores arbitrary tab values without creating atoms" do
      value = "not_a_tab_#{System.unique_integer([:positive])}"
      socket = socket(%{active_tab: :overview})

      assert {:noreply, returned} = Page.handle_event("select_tab", %{"tab" => value}, socket)
      assert returned.assigns.active_tab == :overview
      assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
    end
  end

  describe "metric pagination" do
    test "bounds the rendered page and filters outside render" do
      metrics = for n <- 1..10_000, do: "telemetry.group.metric_#{n}"

      first = Page.metric_page(metrics, "", 1, 200)
      assert first.total == 10_000
      assert first.page_count == 50
      assert first.groups |> Enum.flat_map(&elem(&1, 1)) |> length() == 200

      filtered = Page.metric_page(metrics, "metric_9999", 1, 200)
      assert filtered.total == 1
      assert filtered.groups |> Enum.flat_map(&elem(&1, 1)) == ["telemetry.group.metric_9999"]
    end
  end

  describe "chart series selection" do
    test "ranks high-volume series first" do
      series = [
        %{labels: %{"host" => "quiet"}, data: [{1, 1.0}, {2, 1.0}]},
        %{labels: %{"host" => "busy"}, data: [{1, -10.0}, {2, 20.0}]}
      ]

      assert [%{labels: %{"host" => "busy"}} | _] = Page.rank_series(series)
    end
  end

  describe "alerts" do
    test "persists ntfy format from the form and restores it for editing" do
      socket =
        socket(%{
          store: @store,
          editing_alert: nil,
          flash_timer: nil,
          alerts: [],
          alert_history: [],
          show_alert_form: true,
          alert_form: %{},
          metric_names: []
        })

      params = %{
        "name" => "ntfy alert",
        "metric" => "test.metric",
        "condition" => "above",
        "threshold" => "10",
        "duration" => "0",
        "aggregate" => "avg",
        "webhook_url" => "https://ntfy.sh/operators",
        "webhook_format" => "ntfy"
      }

      assert {:noreply, saved_socket} = Page.handle_event("save_alert", params, socket)
      assert [%{webhook_format: "ntfy"} = alert] = saved_socket.assigns.alerts

      assert {:noreply, editing_socket} =
               Page.handle_event(
                 "edit_alert",
                 %{"id" => Integer.to_string(alert.id)},
                 saved_socket
               )

      assert editing_socket.assigns.alert_form["webhook_format"] == "ntfy"
    end

    test "an older flash timer cannot clear a newer message" do
      socket =
        socket(%{
          store: @store,
          editing_alert: nil,
          flash_timer: nil,
          alerts: [],
          alert_history: [],
          show_alert_form: true,
          alert_form: %{},
          metric_names: []
        })

      params = %{
        "name" => "temporary",
        "metric" => "test.metric",
        "condition" => "above",
        "threshold" => "10",
        "duration" => "0",
        "aggregate" => "avg",
        "webhook_url" => "",
        "webhook_format" => "generic"
      }

      assert {:noreply, created_socket} = Page.handle_event("save_alert", params, socket)
      [alert] = created_socket.assigns.alerts
      old_token = created_socket.assigns.flash_timer.token

      assert {:noreply, deleted_socket} =
               Page.handle_event(
                 "delete_alert",
                 %{"id" => Integer.to_string(alert.id)},
                 created_socket
               )

      assert deleted_socket.assigns.flash_msg == "Alert deleted"

      assert {:noreply, unchanged_socket} =
               Page.handle_info({:clear_flash, old_token}, deleted_socket)

      assert unchanged_socket.assigns.flash_msg == "Alert deleted"
    end
  end

  describe "storage" do
    test "handles stores without a database path and missing backup directories" do
      assert Page.list_backups(%{db_path: nil}) == []
      assert Page.list_backups(%{db_path: "/definitely/missing/timeless.db"}) == []
    end

    test "runs backup work outside the LiveView process" do
      socket =
        socket(%{
          store: @store,
          info: TimelessMetrics.info(@store),
          backup_task: nil,
          flash_timer: nil,
          storage_loaded_at: nil,
          backups: []
        })

      assert {:noreply, running_socket} = Page.handle_event("trigger_backup", %{}, socket)
      assert %{ref: ref} = running_socket.assigns.backup_task

      assert_receive {:maintenance_finished, :backup, ^ref, result}, 5_000

      assert {:noreply, finished_socket} =
               Page.handle_info({:maintenance_finished, :backup, ref, result}, running_socket)

      assert finished_socket.assigns.backup_task == nil
      assert finished_socket.assigns.backups != []
      assert finished_socket.assigns.flash_msg =~ "Backup created"

      assert {:noreply, rate_limited_socket} =
               Page.handle_event("trigger_backup", %{}, finished_socket)

      assert rate_limited_socket.assigns.backup_task == nil
      assert rate_limited_socket.assigns.flash_msg =~ "Please wait"
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

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end
end
