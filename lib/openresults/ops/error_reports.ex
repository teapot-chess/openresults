defmodule OpenResults.Ops.ErrorReports do
  @moduledoc """
  Crash reports, kept here rather than sent to somebody else's dashboard.

  The usual answer to "tell me when it breaks" is a hosted error tracker, and
  the usual price is that every stack trace - with whatever the failing code
  happened to be holding - leaves for a company in another jurisdiction. The
  operator is in the EU and the data is about chess players, so the crashes
  stay on the box, in a table, on an admin page (`/admin/system`).

  ## What gets in

  Anything logged at `:error` or worse that carries a `crash_reason` - which
  is what Elixir's logger attaches to a crashed process, LiveView, request or
  task (`OpenResults.Ops.ErrorReports.LoggerHandler`). Exceptions Plug maps
  to a 4xx are not crashes and are skipped: a 404 is somebody's typo.

  ## What is kept out, deliberately

  The stack is stored as `Module.function/arity (file:line)` and nothing else.
  The top frame of a `FunctionClauseError` carries the ARGUMENTS in place of
  the arity, and arguments are exactly where a password or an e-mail address
  would be, so they are counted and dropped.

  Messages are cut back hard, because many of Elixir's own messages embed the
  term they choked on: a `MatchError` prints the whole right-hand side, a
  `KeyError` the whole map, an invalid changeset its changes. Only the first
  paragraph survives, any inspected term after a colon becomes `[term]`,
  anything shaped like an e-mail address or a long token is replaced, and the
  result is capped at 300 characters. That loses detail; detail is what the
  stack and the server log are for.

  Requests are never looked at: no params, no body, no headers, no session.

  ## Bounded

  One row per fingerprint (the exception's module and its top frames, no
  line numbers - so the same bug after a deploy is the same row), with a
  count and first/last seen. At most `#{200}` rows; the least recently seen
  go first.
  """

  import Ecto.Query

  alias OpenResults.Ops.ErrorReport
  alias OpenResults.Repo

  @max_rows 200
  @max_frames 20
  @fingerprint_frames 5
  @max_message 300

  @type report :: %{
          fingerprint: String.t(),
          kind: String.t(),
          message: String.t(),
          location: String.t() | nil,
          stacktrace: String.t()
        }

  @doc """
  Turns a logger `crash_reason` into a sanitized report, or `:ignore` for a
  4xx-shaped exception. Pure: nothing is written.
  """
  @spec from_crash(term()) :: report() | :ignore
  def from_crash({reason, stacktrace}) when is_list(stacktrace) do
    if client_error?(reason), do: :ignore, else: build(reason, stacktrace)
  end

  def from_crash(reason), do: build(reason, [])

  defp build(reason, stacktrace) do
    {kind, message} = describe(reason)
    frames = stacktrace |> Enum.take(@max_frames) |> Enum.map(&frame/1)
    location = Enum.find(frames, fn {app?, _} -> app? end) || List.first(frames)

    key =
      [kind | frames |> Enum.take(@fingerprint_frames) |> Enum.map(fn {_, f} -> f.mfa end)]
      |> Enum.join("|")

    %{
      fingerprint:
        :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 16),
      kind: kind,
      message: message,
      location: location && elem(location, 1).mfa,
      stacktrace: Enum.map_join(frames, "\n", fn {_, f} -> f.line end)
    }
  end

  defp client_error?(reason) do
    is_exception(reason) and Plug.Exception.status(reason) < 500
  rescue
    _ -> false
  end

  defp describe({:nocatch, value}), do: {"throw", "throw: " <> shape(value, 0)}

  defp describe(reason) when is_exception(reason) do
    message =
      try do
        Exception.message(reason)
      rescue
        _ -> "(message unavailable)"
      end

    {inspect(reason.__struct__), sanitize_message(message)}
  end

  defp describe(reason), do: {"exit", "exit: " <> shape(reason, 0)}

  @doc false
  # Public for the tests, which are the specification.
  def sanitize_message(message) when is_binary(message) do
    message
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> hd()
    |> then(&Regex.replace(~r/(:\s+)(%|\{|\[|"|<<|'|#[A-Z]).*\z/su, &1, "\\1[term]"))
    |> scrub()
    |> String.slice(0, @max_message)
  end

  def sanitize_message(_), do: "(no message)"

  @email ~r/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/
  @token ~r/[A-Za-z0-9_\-+\/=]{24,}/

  defp scrub(text) do
    text
    |> then(&Regex.replace(@email, &1, "[email]"))
    |> then(&Regex.replace(@token, &1, "[redacted]"))
  end

  # The outline of a term without its contents: atoms and module names are
  # code, everything else is data and only its type is kept.
  defp shape(term, depth) when is_atom(term) and depth < 3, do: inspect(term)
  defp shape(term, _depth) when is_number(term), do: "[number]"
  defp shape(term, _depth) when is_binary(term), do: "[string]"
  defp shape(term, _depth) when is_list(term), do: "[list]"
  defp shape(term, _depth) when is_map(term), do: "[map]"

  defp shape(term, depth) when is_tuple(term) and tuple_size(term) <= 4 and depth < 2 do
    "{" <> (term |> Tuple.to_list() |> Enum.map_join(", ", &shape(&1, depth + 1))) <> "}"
  end

  defp shape(_term, _depth), do: "..."

  defp frame({module, fun, arity_or_args, location}) do
    arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args
    mfa = Exception.format_mfa(module, fun, arity)

    where =
      case {location[:file], location[:line]} do
        {nil, _} -> ""
        {file, nil} -> " (#{file})"
        {file, line} -> " (#{file}:#{line})"
      end

    {app_module?(module), %{mfa: mfa, line: mfa <> where}}
  end

  defp frame({fun, arity_or_args, location}) when is_function(fun) do
    arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args
    {false, %{mfa: "fn/#{arity}", line: "fn/#{arity} (#{location[:file]}:#{location[:line]})"}}
  end

  defp frame(_other), do: {false, %{mfa: "?", line: "?"}}

  defp app_module?(module) do
    String.starts_with?(Atom.to_string(module), app_prefixes())
  end

  defp app_prefixes,
    do: ["Elixir.OpenResults", "Elixir.Mix.Tasks.Openresults", "Elixir.Mix.Tasks.Ops"]

  # -- storage -------------------------------------------------------------

  @doc """
  Records a report: a new row for a new fingerprint, otherwise one more on the
  count. Returns `{:new, row}` or `{:seen, row}`.
  """
  @spec record(report(), DateTime.t()) :: {:new | :seen, struct()} | {:error, term()}
  def record(report, now \\ DateTime.utc_now(:second)) do
    case Repo.get_by(ErrorReport, fingerprint: report.fingerprint) do
      nil ->
        row =
          Repo.insert!(%ErrorReport{
            fingerprint: report.fingerprint,
            kind: report.kind,
            message: report.message,
            location: report.location,
            stacktrace: report.stacktrace,
            count: 1,
            first_seen_at: now,
            last_seen_at: now
          })

        prune()
        {:new, row}

      row ->
        {1, _} =
          from(r in ErrorReport, where: r.id == ^row.id)
          |> Repo.update_all(
            inc: [count: 1],
            set: [last_seen_at: now, message: report.message, stacktrace: report.stacktrace]
          )

        {:seen, %{row | count: row.count + 1, last_seen_at: now}}
    end
  rescue
    error -> {:error, error}
  end

  defp prune do
    keep =
      from(r in ErrorReport,
        order_by: [desc: r.last_seen_at, desc: r.id],
        limit: @max_rows,
        select: r.id
      )

    from(r in ErrorReport, where: r.id not in subquery(keep)) |> Repo.delete_all()
  end

  @doc "Every stored report, most recently seen first."
  def list do
    Repo.all(from r in ErrorReport, order_by: [desc: r.last_seen_at, desc: r.id])
  end

  @doc "One stored report by id - an integer or its text from a URL - or `nil`."
  def get(id) when is_integer(id), do: Repo.get(ErrorReport, id)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> get(n)
      _ -> nil
    end
  end

  def get(_id), do: nil

  @doc "Forgets one report (it was fixed, or it was noise)."
  def delete(id), do: from(r in ErrorReport, where: r.id == ^id) |> Repo.delete_all()

  @doc "Forgets all of them."
  def clear, do: Repo.delete_all(ErrorReport)

  @doc false
  def max_rows, do: @max_rows
end
