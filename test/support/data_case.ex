defmodule OpenResults.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use OpenResults.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias OpenResults.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import OpenResults.DataCase
    end
  end

  setup tags do
    OpenResults.DataCase.setup_sandbox(tags)
    OpenResults.DataCase.reset_shared_caches()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OpenResults.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Empties the snapshot id/body cache and the rendered-page cache before a
  test runs.

  These three ETS tables are now supervised (see `OpenResults.Application`
  and the moduledocs of `OpenResults.Snapshots.LatestIdCache` and
  `OpenResults.Snapshots.BodyCache`) so that they survive for the life of
  the node rather than dying with whichever connection happened to create
  them - which is the fix a 2026-09-12 load-test re-run found necessary. The
  Ecto Sandbox undoes a test's own database writes, but it has no idea
  these ETS tables exist, and several tests publish the very same fixture
  payload under the very same slug - so without this, a snapshot cached by
  an earlier test looks, to a later one, exactly like the tournament it is
  about to publish, and `Snapshots.store/3`'s idempotent-repeat check
  collapses a genuinely new insert into "unchanged", silently, at whichever
  test happens to run second.

  Not a fix for `async: true` tests that share a slug and genuinely run at
  the same time - clearing at the start of a test cannot stop a sibling
  test's write arriving mid-run. `OpenResults.SnapshotsTest` is `async:
  false` for exactly that reason, matching this module's own moduledoc
  advice against `async: true` on a database that is not Postgres.
  """
  def reset_shared_caches do
    OpenResults.Snapshots.clear_cache()
    OpenResultsWeb.Plugs.Revalidate.Page.clear()
    # Visibility, for the same reason as the two above - and it matters more
    # here, because a status cached by one test's rolled-back row would make a
    # tournament in the next test hidden for no reason anybody could find.
    OpenResults.Tournaments.StatusCache.clear()
    # The epochs a grouped tournament's ETag carries: bumped by one test's
    # siblings, and no business of the next.
    OpenResults.TournamentGroups.Epochs.clear()
    # The results hub's cache generations, for the same reason.
    OpenResults.ResultsIndex.Generations.clear()
    # Server settings and the public notice: a value one test saved in the
    # panel is rolled back with its row, and must not outlive it here.
    OpenResults.ServerSettings.clear_cache()
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
