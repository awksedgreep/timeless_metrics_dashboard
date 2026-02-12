defmodule TimelessDashboard.DownloadPlug do
  @moduledoc """
  Plug that serves Timeless backup downloads as tar.gz archives.

  Mount in your router alongside the LiveDashboard page:

      forward "/timeless/downloads", TimelessDashboard.DownloadPlug, store: :metrics

  Then backups listed on the Storage tab will have download links.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    %{store: Keyword.fetch!(opts, :store)}
  end

  @impl true
  def call(%{path_info: ["backups", name]} = conn, %{store: store}) do
    # Sanitize: no slashes, no dots-only, no path traversal
    if name =~ ~r/^[a-zA-Z0-9_\-]+$/ do
      info = Timeless.info(store)
      data_dir = Path.dirname(info.db_path)
      backup_path = Path.join([data_dir, "backups", name])

      if File.dir?(backup_path) do
        serve_tar_gz(conn, name, backup_path)
      else
        conn |> send_resp(404, "Backup not found") |> halt()
      end
    else
      conn |> send_resp(400, "Invalid backup name") |> halt()
    end
  rescue
    e ->
      require Logger
      Logger.error("TimelessDashboard.DownloadPlug: #{Exception.message(e)}")
      conn |> send_resp(500, "Download failed: #{Exception.message(e)}") |> halt()
  catch
    :exit, reason ->
      require Logger
      Logger.error("TimelessDashboard.DownloadPlug: #{inspect(reason)}")
      conn |> send_resp(500, "Download failed: store not available") |> halt()
  end

  def call(conn, _opts) do
    conn |> send_resp(404, "Not found") |> halt()
  end

  defp serve_tar_gz(conn, name, backup_path) do
    tmp_tar =
      Path.join(
        System.tmp_dir!(),
        "timeless_backup_#{name}_#{:erlang.unique_integer([:positive])}.tar.gz"
      )

    # Use {name_in_tar, full_path} tuples so the tar has clean filenames
    files =
      backup_path
      |> File.ls!()
      |> Enum.map(fn filename ->
        {String.to_charlist(filename), String.to_charlist(Path.join(backup_path, filename))}
      end)

    :ok = :erl_tar.create(String.to_charlist(tmp_tar), files, [:compressed])
    tar_data = File.read!(tmp_tar)
    File.rm(tmp_tar)

    conn
    |> put_resp_content_type("application/gzip")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="timeless_backup_#{name}.tar.gz")
    )
    |> send_resp(200, tar_data)
  end
end
