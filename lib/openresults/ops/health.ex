defmodule OpenResults.Ops.Health do
  @moduledoc """
  What `/healthz` says, and what the System admin page repeats.

  Deliberately poor in information, because the endpoint is public: a
  status, the app's version (already in every page footer), and a word per
  check. No counts, no hostnames, no paths, no error text - a stranger can
  learn that the server is up and which release it runs, and nothing they
  could not learn by loading the front page.

  ## What decides the HTTP status

  Only the database. A monitor, a load balancer or the deploy script's
  "did it come back" check wants to know whether this process can serve a
  page, and without the database it cannot. The off-site backup is reported
  beside it and never flips the status: a bucket that is unreachable for an
  afternoon is the operator's problem, not a reason for anything automated
  to declare the app dead and restart it - which would fix nothing and drop
  every hall display's socket.

  The FIDE list's own database (`OpenResults.FideList.Repo`) is not asked
  either: the site serves every page without it, and the entry form already
  says "not yet" when it is missing.
  """

  alias OpenResults.Ops.OffsiteBackup
  alias OpenResults.Repo

  @doc "The report: `%{status: \"ok\" | \"degraded\", version: ..., checks: %{...}}`."
  def report do
    database = database()

    %{
      status: if(database == "ok", do: "ok", else: "degraded"),
      version: version(),
      checks: %{database: database, backup: Atom.to_string(backup())}
    }
  end

  defp database do
    case Repo.query("SELECT 1", [], timeout: 2_000, log: false) do
      {:ok, _} -> "ok"
      _ -> "unreachable"
    end
  rescue
    _ -> "unreachable"
  catch
    :exit, _ -> "unreachable"
  end

  defp backup do
    OffsiteBackup.status()
  catch
    :exit, _ -> :failing
  end

  defp version, do: :openresults |> Application.spec(:vsn) |> to_string()
end
