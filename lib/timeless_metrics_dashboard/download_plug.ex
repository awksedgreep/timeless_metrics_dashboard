if Code.ensure_loaded?(Plug.Conn) do
  defmodule TimelessMetricsDashboard.DownloadPlug do
    @moduledoc """
    Plug that serves Timeless backup downloads as tar.gz archives.

    Mount in your router alongside the LiveDashboard page:

        forward "/timeless/downloads", TimelessMetricsDashboard.DownloadPlug, store: :metrics

    Then backups listed on the Storage tab will have download links.

    Options:

      * `:store` — Timeless store name (required)
      * `:auth_token` — optional bearer token required for every download
      * `:serialize_downloads` — allow only one archive build/download per store
        at a time (default: `true`)
    """

    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts) do
      %{
        store: Keyword.fetch!(opts, :store),
        auth_token: Keyword.get(opts, :auth_token),
        serialize_downloads: Keyword.get(opts, :serialize_downloads, true)
      }
    end

    @impl true
    def call(conn, %{auth_token: auth_token} = opts) when is_binary(auth_token) do
      expected = "Bearer " <> auth_token

      authorized? =
        Enum.any?(get_req_header(conn, "authorization"), fn supplied ->
          byte_size(supplied) == byte_size(expected) &&
            Plug.Crypto.secure_compare(supplied, expected)
        end)

      if authorized? do
        call_authorized(conn, opts)
      else
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="timeless backups"))
        |> send_resp(401, "Unauthorized")
        |> halt()
      end
    end

    def call(conn, opts), do: call_authorized(conn, opts)

    defp call_authorized(%{path_info: ["backups", name]} = conn, %{store: store} = opts) do
      # Sanitize: no slashes, no dots-only, no path traversal
      if name =~ ~r/^[a-zA-Z0-9_\-]+$/ do
        info = TimelessMetrics.info(store)

        if is_binary(info.db_path) do
          data_dir = Path.dirname(info.db_path)
          backup_path = Path.join([data_dir, "backups", name])

          if File.dir?(backup_path) do
            serve_with_lock(conn, name, backup_path, opts)
          else
            conn |> send_resp(404, "Backup not found") |> halt()
          end
        else
          conn |> send_resp(404, "Backup storage is unavailable") |> halt()
        end
      else
        conn |> send_resp(400, "Invalid backup name") |> halt()
      end
    rescue
      e ->
        require Logger
        Logger.error("TimelessMetricsDashboard.DownloadPlug: #{Exception.message(e)}")
        conn |> send_resp(500, "Download failed: #{Exception.message(e)}") |> halt()
    catch
      :exit, reason ->
        require Logger
        Logger.error("TimelessMetricsDashboard.DownloadPlug: #{inspect(reason)}")
        conn |> send_resp(500, "Download failed: store not available") |> halt()
    end

    defp call_authorized(conn, _opts) do
      conn |> send_resp(404, "Not found") |> halt()
    end

    defp serve_with_lock(conn, name, backup_path, %{serialize_downloads: false}) do
      serve_tar_gz(conn, name, backup_path)
    end

    defp serve_with_lock(conn, name, backup_path, %{store: store}) do
      lock = {{__MODULE__, store}, self()}

      if :global.set_lock(lock, [node()], 0) do
        try do
          serve_tar_gz(conn, name, backup_path)
        after
          :global.del_lock(lock, [node()])
        end
      else
        conn
        |> put_resp_header("retry-after", "5")
        |> send_resp(429, "Another backup download is already in progress")
        |> halt()
      end
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

      try do
        :ok = :erl_tar.create(String.to_charlist(tmp_tar), files, [:compressed])

        conn =
          conn
          |> put_resp_content_type("application/gzip")
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="timeless_backup_#{name}.tar.gz")
          )
          |> send_chunked(200)

        tmp_tar
        |> File.stream!(64 * 1024, [])
        |> Enum.reduce_while(conn, fn data, conn ->
          case chunk(conn, data) do
            {:ok, conn} -> {:cont, conn}
            {:error, _reason} -> {:halt, conn}
          end
        end)
        |> halt()
      after
        File.rm(tmp_tar)
      end
    end
  end
end
