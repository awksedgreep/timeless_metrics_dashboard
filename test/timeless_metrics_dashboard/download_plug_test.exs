defmodule TimelessMetricsDashboard.DownloadPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias TimelessMetricsDashboard.DownloadPlug

  @store :download_plug_test_store

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "timeless_download_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)
    start_supervised!({TimelessMetrics, name: @store, data_dir: data_dir})

    info = TimelessMetrics.info(@store)
    backup_name = "backup_#{System.unique_integer([:positive])}"
    backup_path = Path.join([Path.dirname(info.db_path), "backups", backup_name])
    File.mkdir_p!(backup_path)
    File.write!(Path.join(backup_path, "metrics.db"), :binary.copy("data", 1_000))

    on_exit(fn -> File.rm_rf!(data_dir) end)

    %{backup_name: backup_name}
  end

  test "streams fixed-size chunks and always removes its temporary archive", %{
    backup_name: backup_name
  } do
    prefix = "timeless_backup_#{backup_name}_"
    before = temporary_archives(prefix)

    conn =
      :get
      |> conn("/backups/#{backup_name}")
      |> DownloadPlug.call(DownloadPlug.init(store: @store))

    assert conn.status == 200
    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") == ["application/gzip; charset=utf-8"]
    assert temporary_archives(prefix) == before
  end

  test "supports optional bearer authentication", %{backup_name: backup_name} do
    opts = DownloadPlug.init(store: @store, auth_token: "secret")

    unauthorized =
      :get
      |> conn("/backups/#{backup_name}")
      |> DownloadPlug.call(opts)

    assert unauthorized.status == 401

    authorized =
      :get
      |> conn("/backups/#{backup_name}")
      |> put_req_header("authorization", "Bearer secret")
      |> DownloadPlug.call(opts)

    assert authorized.status == 200
  end

  test "rejects a concurrent archive download", %{backup_name: backup_name} do
    parent = self()

    holder =
      spawn(fn ->
        lock = {{DownloadPlug, @store}, self()}
        true = :global.set_lock(lock, [node()], 0)
        send(parent, :lock_held)

        receive do
          :release -> :global.del_lock(lock, [node()])
        end
      end)

    assert_receive :lock_held

    conn =
      :get
      |> conn("/backups/#{backup_name}")
      |> DownloadPlug.call(DownloadPlug.init(store: @store))

    assert conn.status == 429
    send(holder, :release)
  end

  defp temporary_archives(prefix) do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
  end
end
