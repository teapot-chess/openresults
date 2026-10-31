defmodule OpenResultsWeb.HealthController do
  @moduledoc """
  `GET /healthz`: 200 and `"status": "ok"` when the database answers, 503 and
  `"degraded"` when it does not. See `OpenResults.Ops.Health` for what is
  in the body and why so little.

  Routed outside every pipeline: no locale, no CSP, no visibility, no
  revalidation, no session (the public side has none anyway), no rate limit
  (there is none outside the controllers that call `OpenResults.RateLimit`),
  and no log line (`log: false` on the route). Not counted on the stats
  page either - see `OpenResultsWeb.StatsTelemetry`. Never cached.
  """
  use OpenResultsWeb, :controller

  alias OpenResults.Ops.Health

  def show(conn, _params) do
    report = Health.report()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(if report.status == "ok", do: 200, else: 503)
    |> json(report)
  end
end
