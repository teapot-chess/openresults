defmodule OpenResultsWeb.EntryFieldsTest do
  @moduledoc """
  Title and birth year, which the arbiter's own form collected and this one
  did not.

  Neither is required and neither blocks an entry. They are here because the
  arbiter has to type them otherwise, and because a birth year is what tells
  two players with the same name apart - which is a real problem in a club
  where three generations of one family play.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResults.Registrations.Entry
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  setup do
    RateLimit.reset()
    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, slug: swiss["tournament"]["slug"]}
  end

  defp entry(overrides \\ %{}) do
    Map.merge(%{"name" => "De Vos, Ilse", "email" => "ilse@example.invalid"}, overrides)
  end

  defp submit(conn, slug, attrs), do: post(conn, ~p"/t/#{slug}/register", registration: attrs)

  defp stored(slug) do
    slug |> Registrations.list_for_tournament() |> List.last()
  end

  describe "the form offers them" do
    test "a title is a closed list, not a text box", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)

      # Free text would collect "gm", "Grandmaster" and "GM (inactive)", and
      # the arbiter would normalise every one of them by hand.
      assert html =~ ~s|name="registration[title]"|
      assert html =~ "<option value=\"GM\">"
      assert html =~ "<option value=\"WCM\">"

      # And an empty option, because a closed vocabulary with no way to say
      # "none of these" turns an optional field into a required one.
      assert html =~ "<option value=\"\">None</option>"
    end

    test "a birth year is offered and explained", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)

      assert html =~ ~s|name="registration[birth_year]"|
      assert html =~ "rather not say"
    end
  end

  describe "what reaches the arbiter" do
    test "both travel in the stored document", %{conn: conn, slug: slug} do
      submit(conn, slug, entry(%{"title" => "WFM", "birth_year" => "1994"}))

      player = stored(slug).payload["player"]

      assert player["title"] == "WFM"
      assert player["birth_year"] == 1994
    end

    test "an entry without them is still perfectly valid", %{conn: conn, slug: slug} do
      conn = submit(conn, slug, entry())

      assert html_response(conn, 200) =~ "sent"

      player = stored(slug).payload["player"]
      refute Map.has_key?(player, "title")
      refute Map.has_key?(player, "birth_year")
    end
  end

  describe "the FIDE search" do
    # A list database of this test's own, empty until a test imports the
    # fixture into it - see `OpenResults.FideListCase`.
    setup context, do: OpenResults.FideListCase.setup_fide_list(context)

    test "is not offered where there is no list and none is coming", %{conn: conn, slug: slug} do
      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)

      # A search box that cannot search is worse than none: it invites a click
      # and answers nothing. The sync is off in tests and no list is here.
      #
      # Asserted on the label rather than the element id: the id also appears
      # in the script that looks for the panel, so refuting it would pass
      # whether or not the panel rendered. (Second time today - the same trap
      # caught the refresher's test.)
      refute html =~ "Find yourself on the FIDE list"
      refute html =~ ~s|id="fide-search-pending"|
      assert html =~ ~s|name="registration[name]"|
    end

    test "says it is not there yet while the first list is on its way", %{
      conn: conn,
      slug: slug
    } do
      Application.put_env(:openresults, :fide_list_sync, true)
      on_exit(fn -> Application.put_env(:openresults, :fide_list_sync, false) end)

      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)

      assert html =~ ~s|id="fide-search-pending"|
      refute html =~ "Find yourself on the FIDE list"
    end

    test "is offered once a list is here", %{conn: conn, slug: slug} = context do
      OpenResults.FideListCase.import_fixture!(context)

      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)

      assert html =~ "fide-search"
      assert html =~ "Find yourself on the FIDE list"
      # And it says plainly that it is optional, because a player who is not
      # on the FIDE list must not think they are stuck.
      assert html =~ "Optional"
    end

    test "answers from this server's own list", %{conn: conn, slug: slug} = context do
      OpenResults.FideListCase.import_fixture!(context)

      players = conn |> get(~p"/t/#{slug}/fide", q: "de vos") |> json_response(200)

      assert %{"players" => [jan, ilse]} = players
      assert jan["name"] == "De Vos, Jan"
      assert jan["fide_id"] == 901_002
      assert jan["federation"] == "BEL"
      assert jan["title"] == "FM"
      assert jan["birth_year"] == 1980
      assert is_integer(jan["rating"])
      assert ilse["name"] == "De Vos, Ilse"
    end

    test "says the list is not there rather than that nobody matched", %{
      conn: conn,
      slug: slug
    } do
      conn = get(conn, ~p"/t/#{slug}/fide", q: "De Vos")

      assert json_response(conn, 200) == %{"players" => [], "available" => false}
    end

    test "and refuses entirely once entries are closed", %{conn: conn} do
      closed =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "slug"], "closed-event")
        |> put_in(["tournament", "registration_open"], false)

      {:ok, _} = Snapshots.ingest(closed)

      # A tournament not taking entries has no reason to lend anybody a
      # search, and leaving this open would make it reachable for every
      # tournament on the site regardless of the form's own gate.
      conn = get(conn, ~p"/t/closed-event/fide", q: "De Vos")

      assert json_response(conn, 403)
    end
  end

  describe "what is refused" do
    test "a title FIDE does not award" do
      changeset = Entry.changeset(entry(%{"title" => "SuperGM"}), [])

      refute changeset.valid?

      assert {"that is not a FIDE title - leave it empty if you do not have one", _} =
               changeset.errors[:title]
    end

    test "a birth year that is really a rating" do
      # The mistake this range exists to catch: 1850 is a plausible rating and
      # an implausible birth year for somebody entering a chess tournament.
      changeset = Entry.changeset(entry(%{"birth_year" => "12"}), [])

      refute changeset.valid?
      assert changeset.errors[:birth_year]
    end

    test "a birth year in the future" do
      changeset = Entry.changeset(entry(%{"birth_year" => "2099"}), [])

      refute changeset.valid?
    end

    test "and nothing is stored when either is wrong", %{conn: conn, slug: slug} do
      submit(conn, slug, entry(%{"title" => "SuperGM"}))

      assert Registrations.list_for_tournament(slug) == []
    end
  end
end
