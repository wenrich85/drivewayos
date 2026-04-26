defmodule DrivewayOS.Uploads do
  @moduledoc """
  Tiny writer for LiveView Upload entries. Copies temp files into
  `priv/static/uploads/<tenant>/<appointment>/<entry_uuid>.<ext>`
  and returns the metadata needed to create a `Scheduling.Photo`
  row.

  V1 ships local-disk only; the public path is served by Plug.Static
  (the `:uploads` directory is whitelisted in `DrivewayOSWeb.static_paths/0`).
  When V2 moves to S3/R2, only this module changes — callers see
  the same map shape come back.
  """

  @uploads_dir "uploads"

  @doc """
  Copy `temp_path` into the public uploads tree under
  `<tenant>/<appointment>/`. Returns `{:ok, %{path, content_type, byte_size}}`
  where `path` is the URL-relative path (`"/uploads/..."`) suitable
  for both `<img src>` and the Photo row's `storage_path`.
  """
  @spec store_entry(binary(), binary(), Phoenix.LiveView.UploadEntry.t(), Path.t()) ::
          {:ok, %{path: String.t(), content_type: String.t(), byte_size: non_neg_integer()}}
          | {:error, term()}
  def store_entry(tenant_id, appointment_id, %Phoenix.LiveView.UploadEntry{} = entry, temp_path) do
    ext = file_extension(entry)
    filename = "#{entry.uuid}#{ext}"
    rel_dir = Path.join([@uploads_dir, tenant_id, appointment_id])
    abs_dir = Path.join(static_root(), rel_dir)

    with :ok <- File.mkdir_p(abs_dir),
         :ok <- File.cp(temp_path, Path.join(abs_dir, filename)),
         {:ok, %File.Stat{size: size}} <- File.stat(Path.join(abs_dir, filename)) do
      {:ok,
       %{
         path: "/" <> Path.join([rel_dir, filename]),
         content_type: entry.client_type || "application/octet-stream",
         byte_size: size
       }}
    end
  end

  defp static_root do
    Application.app_dir(:driveway_os, "priv/static")
  end

  defp file_extension(%Phoenix.LiveView.UploadEntry{client_name: name}) when is_binary(name) do
    case Path.extname(name) do
      "" -> ""
      ext -> String.downcase(ext)
    end
  end

  defp file_extension(_), do: ""
end
