defmodule OpenResults.FideList.Source do
  @moduledoc """
  Where the list comes from, and whether it has changed since last time.

  ## "Only if new"

  Ratings change once a month. The file does not wait for them: FIDE
  rebuilds it whenever it likes - the copy served on 2026-10-18 was dated the
  17th - with new registrations in it. So whether today's 45 MB are worth
  downloading is decided by a `HEAD` request, a few hundred bytes, whose
  validators are compared with the ones recorded when the live list was
  imported (`changed?/2`). Measured on 2026-10-18, FIDE sends an `ETag`
  (nginx's: modification time and size), a `Last-Modified` and a
  `Content-Length`.

    1. both sides have an `ETag`: changed when they differ;
    2. otherwise both have a `Last-Modified`: changed when it differs, or
       when the `Content-Length` does (where both have one);
    3. otherwise: changed. A server that dates nothing gets downloaded daily,
       which is wasteful and still correct.

  A server that refuses `HEAD` outright gets a conditional `GET` instead
  (`If-None-Match` / `If-Modified-Since`), and a `304` counts as unchanged.
  A `HEAD` that fails for a network reason is a failed check and no `GET`:
  a server that is unreachable for a few hundred bytes is not about to send
  forty megabytes.

  ## The download

  Streamed to a file, never held in memory: the request's body goes to disk
  as it arrives, with a byte ceiling that abandons it mid-stream.

  `config :openresults, :fide_list_req_options` is merged into every request,
  so tests route them to a `Req.Test` stub.
  """

  @default_url "https://ratings.fide.com/download/players_list.zip"

  # The real zip is about 45 MB. Generous, and still a bound on what a
  # redirected or misbehaving endpoint can pour onto this disk.
  @max_download_bytes 250_000_000

  @type fingerprint :: %{
          etag: String.t() | nil,
          last_modified: String.t() | nil,
          content_length: String.t() | nil
        }

  @doc """
  The list's address: FIDE's by default, `FIDE_LIST_URL` otherwise.

  The override exists because ratings.fide.com has been known to block whole
  hosting ranges, which leaves a server on a download that can never succeed.
  Whatever it points at is trusted as FIDE is - its contents become the list
  the entry form fills names from - so only point it at something you control.
  """
  def url do
    case Application.get_env(:openresults, :fide_list_url) do
      url when is_binary(url) and url != "" -> url
      _unset -> @default_url
    end
  end

  @doc "The validators the server sent with `resp`."
  @spec fingerprint(Req.Response.t()) :: fingerprint()
  def fingerprint(%Req.Response{} = resp) do
    %{
      etag: header(resp, "etag"),
      last_modified: header(resp, "last-modified"),
      content_length: header(resp, "content-length")
    }
  end

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end

  @doc """
  Whether the remote list differs from the one recorded in `stored` (the meta
  table's `"etag"`, `"last_modified"`, `"content_length"`). No stored list is
  always "changed".
  """
  @spec changed?(fingerprint(), map() | nil) :: boolean()
  def changed?(_remote, nil), do: true

  def changed?(remote, stored) do
    etag = Map.get(stored, "etag")
    modified = Map.get(stored, "last_modified")
    length = Map.get(stored, "content_length")

    cond do
      remote.etag && etag ->
        remote.etag != etag

      remote.last_modified && modified ->
        remote.last_modified != modified or
          (remote.content_length != nil and length != nil and remote.content_length != length)

      true ->
        true
    end
  end

  @doc """
  The `HEAD` look: `{:ok, fingerprint}`, `{:refused, status}` for a server
  that answered but not with a 200 (a conditional GET may still work), or
  `{:error, reason}` for one that could not be reached.
  """
  def head do
    [
      method: :head,
      url: url(),
      retry: false,
      connect_options: [timeout: 10_000],
      receive_timeout: 15_000
    ]
    |> request()
    |> case do
      {:ok, %Req.Response{status: 200} = resp} -> {:ok, fingerprint(resp)}
      {:ok, %Req.Response{status: status}} -> {:refused, status}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  @doc """
  Downloads the list to `path`. With `stored` validators the request is
  conditional, and `:not_modified` is the answer to a `304`.

  `on_progress` is called with the bytes received so far, about once a
  megabyte - the watchdog in `OpenResults.FideList.Sync` lives on it.
  """
  @spec download(Path.t(), map() | nil, (non_neg_integer() -> any())) ::
          {:ok, fingerprint()} | :not_modified | {:error, String.t()}
  def download(path, stored, on_progress) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = :file.open(String.to_charlist(path), [:write, :binary, :raw])

    try do
      Process.put(:fide_list_bytes, 0)
      Process.put(:fide_list_reported, 0)
      Process.put(:fide_list_too_big, false)

      into = fn {:data, data}, {req, resp} ->
        loaded = Process.get(:fide_list_bytes) + byte_size(data)
        Process.put(:fide_list_bytes, loaded)

        cond do
          loaded > @max_download_bytes ->
            Process.put(:fide_list_too_big, true)
            {:halt, {req, resp}}

          true ->
            # Only a 200's body is the list. Anything else is an error page,
            # and writing it would only have to be deleted again.
            if resp.status == 200, do: :ok = :file.write(io, data)

            if loaded - Process.get(:fide_list_reported) >= 1_048_576 do
              Process.put(:fide_list_reported, loaded)
              on_progress.(loaded)
            end

            {:cont, {req, resp}}
        end
      end

      [
        method: :get,
        url: url(),
        headers: conditional_headers(stored),
        into: into,
        retry: false,
        connect_options: [timeout: 30_000],
        # Between chunks, not for the whole transfer.
        receive_timeout: 120_000
      ]
      |> request()
      |> case do
        {:ok, %Req.Response{status: 200} = resp} ->
          if Process.get(:fide_list_too_big) do
            {:error,
             "the download passed #{div(@max_download_bytes, 1_000_000)} MB and was stopped"}
          else
            {:ok, fingerprint(resp)}
          end

        {:ok, %Req.Response{status: 304}} ->
          :not_modified

        {:ok, %Req.Response{status: status}} ->
          {:error, "the list's server answered HTTP #{status}"}

        {:error, reason} ->
          {:error, describe(reason)}
      end
    after
      :file.close(io)
    end
  end

  defp conditional_headers(nil), do: []

  defp conditional_headers(stored) do
    [
      {"if-none-match", Map.get(stored, "etag")},
      {"if-modified-since", Map.get(stored, "last_modified")}
    ]
    |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
  end

  defp request(opts) do
    opts
    |> Keyword.merge(Application.get_env(:openresults, :fide_list_req_options, []))
    |> Req.request()
  end

  defp describe(%Req.TransportError{reason: :timeout}), do: "the list's server timed out"
  defp describe(%Req.TransportError{reason: :closed}), do: "the connection closed early"

  defp describe(%Req.TransportError{reason: reason}),
    do: "network error (#{inspect(reason)})"

  defp describe(%{__exception__: true} = e), do: "request failed (#{inspect(e.__struct__)})"
  defp describe(other), do: "request failed (#{inspect(other)})"
end
