defmodule OpenResultsWeb.SnapshotController do
  @moduledoc """
  Ingest and read-back of published snapshots.

  Four routes. `create` is the trust boundary and is token-gated. `show`
  serves the CURRENT document and is open, because that document contains
  nothing that was withheld - the withholding happened before it was built.
  `history` serves earlier documents and is token-gated, which is the whole
  point of the split. `delete` removes the tournament entirely.

  `create` and `delete` are also gated per-tournament, by the key in the
  `x-openresults-key` header - see `OpenResults.TournamentKeys` for what that
  key is and why it is a second question rather than a stronger version of the
  first. Two different failures, and they get two different statuses on
  purpose: **401** is "you may not talk to this server", from the plug on the
  pipeline, and **403** is "you may, but not to this tournament".

  With public publishing enabled, `create`, `delete` and `history` also take
  an installation key in place of the operator token - only for tournaments
  minted for that installation, and never with break-glass. Which of the two
  credentials a request carries is decided by `OpenResultsWeb.Plugs.IngestAuth`
  and checked per route by `OpenResultsWeb.InstallationAccess` before any
  action here runs; see `docs/public-publishing.md`. `show` reads through
  `OpenResults.Tournaments.public_latest/1`, so a hidden tournament is a 404
  here exactly as it is on every page.

  The key travels in a HEADER and never in the payload. It could not go in the
  document even if the contract wanted it to: `payload` is stored whole and
  verbatim, and `show` serves that column to the public, so a key inside it
  would be written to disk in plaintext and then published on a page. The
  snapshot describes a tournament; credentials belong to the transport, beside
  the bearer token.

  Withholding holds for the current document ONLY. The table is append-only,
  so an earlier row can contain a round the arbiter has since RETRACTED - a
  wrong result entered, republished without it - or a board they have since
  hidden. Serving those by timestamp on an open endpoint hands back exactly
  what the arbiter withdrew, and it was reproducible: publish rounds 1,2,3,5,
  retract round 3, and `?at=` returned round 3 with its boards intact while
  the page one link away correctly 404'd.

  That is the same failure OpenPairings shipped this week - a backup
  restoring every hidden board into view - through a different door. The
  append-only table is right and stays; its public reachability was the bug.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Moderation
  alias OpenResults.ModerationJournal
  alias OpenResults.Snapshots
  alias OpenResults.Takedown
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ApiError

  # The name is OpenPairings' - it was written first, and one spelling of a
  # header beats two, the same way the contract insists on one spelling of a
  # result token.
  #
  # Read it carefully, because it is easy to misread: this is NOT the
  # OpenResults ingest token, which travels in `Authorization` beside it. This
  # one is per-tournament and the arbiter's machine generated it. The two
  # secrets sit one line apart in every request, so when this is being
  # debugged, check which is which first.
  @key_header "x-openresults-key"

  @doc """
  `POST /api/snapshots` - accepts a published snapshot.

  The first publish carrying a key claims the slug; every later one must
  present the same key. A publish carrying no key at all is accepted for a slug
  nobody has claimed, which is what keeps tournaments published before any of
  this existed - and laptops running a client too old to send a key - on the
  air. `OpenResults.TournamentKeys` has the reasoning.
  """
  def create(conn, _params) do
    # `conn.body_params`, not the `params` Phoenix hands in. Those are the body
    # merged with the query string, and the stored document has to be the body
    # verbatim - otherwise `?rounds=[]` on the publish URL would end up inside
    # a payload that is meant to be exactly what the arbiter's machine built.
    case Snapshots.ingest(conn.body_params,
           key: tournament_key(conn),
           installation: installation(conn)
         ) do
      {:ok, snapshot} ->
        json(conn, %{
          status: "ok",
          slug: snapshot.tournament_slug,
          received_at: DateTime.to_iso8601(snapshot.received_at)
        })

      {:error, reason} when reason in [:key_required, :key_mismatch] ->
        forbid(conn, reason)

      # An installation key, and the ownership check inside the publish
      # transaction disagreed with the one the plug made a moment earlier -
      # a delete or a hide landed in between.
      {:error, reason} when reason in [:not_owner, :tournament_hidden] ->
        ApiError.send(conn, reason)

      # The operator deleted this tournament; see `OpenResults.Tombstones`.
      {:error, :tournament_deleted} ->
        ApiError.send(conn, :tournament_deleted)

      {:error, reason} when is_atom(reason) ->
        reject(conn, reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        reject(conn, :invalid, changeset_detail(changeset))
    end
  end

  @doc """
  `DELETE /api/tournaments/:slug` - removes the tournament from this server.

  Everything: every snapshot including the history, the registration queue,
  and the key claim itself. `OpenResults.Takedown` sets out why a delete that
  removed only the current snapshot would be a bug that reports success.

  Answers 200 with the counts even when nothing was there, because delete is
  idempotent and a client retrying after a timeout should not have to tell a
  404 that means "already gone" from a 404 that means "you typed the slug
  wrong". The counts distinguish those without making the retry an error.
  """
  def delete(conn, %{"slug" => slug}) do
    case TournamentKeys.authorize_delete(slug, tournament_key(conn), break_glass: operator?(conn)) do
      {:ok, form} ->
        deleted = Takedown.purge(slug)

        # The arbiter's withdrawal, written outside the database once it has
        # committed, so a restored backup cannot put the tournament back
        # online: that arbiter's machine threw its key away when this
        # succeeded, and could not withdraw it a second time. See
        # `OpenResults.ModerationJournal`.
        ModerationJournal.record_delete(
          slug,
          if(operator?(conn), do: "operator", else: "owner"),
          DateTime.utc_now()
        )

        log_api_delete(conn, form, slug, deleted)

        json(conn, %{status: "deleted", slug: slug, deleted: deleted})

      {:error, reason} ->
        forbid(conn, reason)
    end
  end

  # The action log's record of who deleted. An installation credential names
  # the installation whatever authorised the key check; break-glass has
  # already been logged by `OpenResults.TournamentKeys` and must not be twice.
  defp log_api_delete(conn, form, slug, deleted) do
    case {installation(conn), form} do
      {%{id: id}, _form} -> Moderation.log_api_delete({:installation, id}, slug, deleted)
      {nil, :break_glass} -> :ok
      {nil, :tournament_key} -> Moderation.log_api_delete(:tournament_key, slug, deleted)
      {nil, :no_key} -> Moderation.log_api_delete(:operator_token, slug, deleted)
    end
  end

  # A repeated header is the client's bug, not an ambiguity to resolve: the
  # first value is used and the rest ignored, the same thing every HTTP stack
  # does with an unexpected duplicate.
  defp tournament_key(conn) do
    case get_req_header(conn, @key_header) do
      [key | _duplicates] -> key
      [] -> nil
    end
  end

  # Which credential the ingest plug accepted. Break-glass - the operator
  # token in the key header - is honoured only for the operator; see
  # `OpenResults.TournamentKeys`.
  defp installation(conn) do
    case conn.assigns[:credential] do
      {:installation, installation} -> installation
      _operator -> nil
    end
  end

  defp operator?(conn), do: conn.assigns[:credential] == :operator

  @doc """
  `GET /api/tournaments/:slug` - returns the CURRENT stored payload.

  `at` is refused here rather than ignored. Ignoring it would answer a
  question about the past with a document about the present, which is worse
  than saying no: a caller asking for 14:00 and getting 18:00 without being
  told has no way to notice. History lives on the authenticated route.
  """
  def show(conn, %{"slug" => _slug} = params) when is_map_key(params, "at") do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "history_requires_auth",
      detail: "earlier snapshots may contain rounds or boards since retracted"
    })
  end

  def show(conn, %{"slug" => slug}) do
    # Through `public_latest/1`, like every public page: a hidden tournament
    # answers exactly what a slug that never published answers.
    case Tournaments.public_latest(slug) do
      nil ->
        not_found(conn, slug)

      snapshot ->
        # The payload as stored, byte for byte in meaning - EXCEPT
        # `publisher`, which this route must never leak: it is the one field
        # in this document that is personal data for a purpose other than
        # describing the tournament (an admin-panel moderation contact), and
        # this is the open, unauthenticated route. See
        # `docs/snapshot-schema.md`'s `publisher` field and
        # `docs/privacy-retention.md`.
        json(conn, public_payload(snapshot.payload))
    end
  end

  defp public_payload(payload) when is_map(payload), do: Map.delete(payload, "publisher")
  defp public_payload(payload), do: payload

  defp not_found(conn, slug) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: "not_found",
      detail: "no tournament has published under this slug",
      slug: slug
    })
  end

  @doc """
  `GET /api/tournaments/:slug/history?at=<ISO 8601>` - the snapshot that was
  current at that instant. Token-gated, because an earlier document can hold
  a round or a board the arbiter has since withdrawn.

  "What did the standings say at 14:00" is an ARBITER's question, and this is
  where an arbiter asks it.
  """
  def history(conn, %{"slug" => slug} = params) do
    case resolve_at(Map.get(params, "at")) do
      {:ok, instant} ->
        case Snapshots.as_of(slug, instant) do
          nil -> not_found(conn, slug)
          # The publisher's email is for the admin panel only - see
          # `public_payload/1` - even to a caller holding the tournament's key.
          snapshot -> json(conn, Map.delete(snapshot.payload, "publisher"))
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "bad_at", detail: "`at` must be an ISO 8601 instant"})
    end
  end

  defp resolve_at(nil), do: :error

  defp resolve_at(at) do
    case DateTime.from_iso8601(at) do
      {:ok, instant, _utc_offset} -> {:ok, instant}
      {:error, _reason} -> :error
    end
  end

  # 403, not 401. The request got past the pipeline's token gate, so it IS
  # allowed to talk to this server - it is this tournament it may not touch.
  # Collapsing the two into one status would tell an arbiter whose publish
  # failed to go and check the wrong secret.
  #
  # And unlike `IngestAuth`, which deliberately gives one indistinguishable
  # answer to every failure, these two say which one happened. That plug is
  # answering the anonymous internet, where "wrong token" versus "no token
  # configured" is free intelligence. By here the caller has already proved it
  # holds the server token, so the only thing the distinction reveals is
  # whether a slug has been claimed - and against that sits an arbiter in a
  # playing hall whose round will not publish, for whom "your client is too old
  # to send a key" and "your key is wrong" have completely different fixes.
  defp forbid(conn, reason) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: Atom.to_string(reason), detail: detail_for(reason)})
  end

  defp reject(conn, reason, detail \\ nil) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Atom.to_string(reason), detail: detail || detail_for(reason)})
  end

  defp detail_for(:not_an_object), do: "the body must be a JSON object"
  defp detail_for(:wrong_schema), do: "`schema` must be #{Snapshots.schema_id()}"
  defp detail_for(:unknown_version), do: "`version` is not a version this server understands"
  defp detail_for(:missing_slug), do: "`tournament.slug` is required"

  defp detail_for(:key_required),
    do: "this tournament has been claimed; send its key in `#{@key_header}`"

  defp detail_for(:key_mismatch),
    do: "`#{@key_header}` is not the key this tournament was claimed with"

  defp changeset_detail(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
