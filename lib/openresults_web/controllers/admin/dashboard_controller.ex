defmodule OpenResultsWeb.Admin.DashboardController do
  @moduledoc """
  The panel's front page: both switches, the counts that say whether
  anything needs looking at, what publishing costs in disk, which FIDE list
  the entry form searches, and the most recent actions.
  """
  use OpenResultsWeb, :controller

  alias OpenResults.Moderation
  alias OpenResults.PublicPublishing

  def show(conn, _params) do
    render(conn, :show,
      page_title: "Dashboard",
      settings: Moderation.settings(),
      counts: Moderation.counts(),
      storage: Moderation.storage(),
      fide_list: OpenResults.FideList.status(),
      actions: Moderation.list_actions(%{limit: 10}),
      public_publishing?: PublicPublishing.enabled?()
    )
  end
end
