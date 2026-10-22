defmodule OpenResultsWeb.LocaleTest do
  @moduledoc """
  Which language a spectator gets, and what the page says about itself.

  The people reading these pages have no account and no settings screen, so
  the browser's `accept-language` is the only thing that can speak for them.
  Everything here is about that header being honoured, being overridable, and
  - the half that is a correctness problem rather than a feature - never
  reaching a reader who asked for something else.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.Locale
  alias OpenResultsWeb.Plugs.Revalidate.Page

  # The footer, which is on every page in the site and whose three versions
  # share no substring. "Standings"/"Stand" would not do: one contains the
  # other, so a Dutch assertion would pass against an English page.
  @english "Results are theirs"
  @dutch "De uitslagen zijn van hen"
  @french "Les résultats sont les siens"

  setup do
    Snapshots.clear_cache()
    Page.clear()

    on_exit(fn ->
      Snapshots.clear_cache()
      Page.clear()
    end)

    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  defp asking(language) do
    build_conn() |> put_req_header("accept-language", language)
  end

  describe "what the browser asks for" do
    test "a Belgian browser asking for Dutch gets Dutch", %{slug: slug} do
      html = "nl-BE,nl;q=0.9,en;q=0.8" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @dutch
      refute html =~ @english
    end

    test "a Walloon browser asking for French gets French", %{slug: slug} do
      html = "fr-BE,fr;q=0.9,en;q=0.8" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @french
      refute html =~ @english
    end

    test "quality values decide, not the order the header happens to be in", %{slug: slug} do
      html = "en;q=0.2,fr;q=0.9" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @french
    end

    test "a language we do not ship falls through to the next one we do", %{slug: slug} do
      html = "de-DE,de;q=0.9,nl;q=0.5" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ @dutch
    end

    test "no header at all is English", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ @english
    end

    # A header is attacker-controlled input on a page anyone can request.
    # There is no reading of it that justifies a 500.
    test "a malformed header is English, not a crash", %{slug: slug} do
      for junk <- [";;;", "q=", "nl;q=banana", ",,,", "*", String.duplicate("x", 5_000), "nl;;q"] do
        Page.clear()
        html = junk |> asking() |> get(~p"/t/#{slug}") |> html_response(200)
        assert html =~ @english or html =~ @dutch
      end
    end
  end

  describe "the explicit choice" do
    test "?lang= outranks the header", %{slug: slug} do
      html =
        "nl-BE,nl;q=0.9"
        |> asking()
        |> get(~p"/t/#{slug}?lang=fr")
        |> html_response(200)

      assert html =~ @french
    end

    test "and is remembered, so the next page keeps the language", %{slug: slug} do
      chosen = "nl" |> asking() |> get(~p"/t/#{slug}?lang=fr")

      # Bound first: a function call cannot appear in a match pattern.
      cookie = Locale.cookie()
      assert %{^cookie => %{value: "fr"}} = chosen.resp_cookies

      html =
        "nl"
        |> asking()
        |> put_req_cookie(Locale.cookie(), "fr")
        |> get(~p"/t/#{slug}")
        |> html_response(200)

      assert html =~ @french
    end

    # The property the router's whole pipeline is built around: no session,
    # so no Set-Cookie, so no consent banner. A language picker nobody used
    # must not cost that.
    test "a reader who never picks a language is never given a cookie", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}") |> Map.fetch!(:resp_cookies) == %{}
      assert "nl" |> asking() |> get(~p"/t/#{slug}") |> Map.fetch!(:resp_cookies) == %{}
    end

    test "a ?lang= we do not ship changes nothing and stores nothing", %{slug: slug} do
      answer = "nl" |> asking() |> get(~p"/t/#{slug}?lang=klingon")

      assert html_response(answer, 200) =~ @dutch
      assert answer.resp_cookies == %{}
    end

    test "the picker offers every language and marks the one you are reading", %{slug: slug} do
      html = "fr" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      for code <- Locale.codes(), do: assert(html =~ ~s|hreflang="#{code}"|)
      assert html =~ ~s|href="/t/#{slug}?lang=nl"|
      assert html =~ ~s|aria-current="true"|
    end

    test "the picker keeps the parameters the page already had", %{slug: slug} do
      html = build_conn() |> get(~p"/t/#{slug}/round/1?display=1") |> html_response(200)

      assert html =~ ~s|href="/t/#{slug}/round/1?display=1&amp;lang=fr"|
    end
  end

  describe "what the response says about itself" do
    test "the html element carries the language it rendered in", %{slug: slug} do
      # Matched on the attribute rather than the whole opening tag: Phoenix
      # adds its own `phx-r` to <html>, so `<html lang="nl">` is never a
      # literal substring of the response and asserting on it would fail
      # while the page was perfectly correct.
      assert "nl" |> asking() |> get(~p"/t/#{slug}") |> html_response(200) =~ ~s|lang="nl"|
      assert "fr" |> asking() |> get(~p"/t/#{slug}") |> html_response(200) =~ ~s|lang="fr"|
    end

    # Without this, any cache between us and the reader is entitled to hand
    # one language's page to somebody who asked for another - the same bug
    # the page cache had, one hop further out.
    test "the response varies on what it read", %{conn: conn, slug: slug} do
      answer = get(conn, ~p"/t/#{slug}")

      # `accept-encoding` is `OpenResultsWeb.Plugs.Revalidate`'s own addition
      # (it now serves a gzip variant to readers who accept one) - merged
      # onto this plug's value, not replacing it.
      assert get_resp_header(answer, "vary") == ["accept-language, cookie, accept-encoding"]
    end
  end

  describe "the pages themselves" do
    test "the standings render in Dutch", %{slug: slug} do
      html = "nl" |> asking() |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ "Stand"
      assert html =~ "na ronde"
    end

    test "a round renders in French", %{slug: slug} do
      html = "fr" |> asking() |> get(~p"/t/#{slug}/round/1") |> html_response(200)

      assert html =~ "Ronde 1"
      assert html =~ "Blancs"
      assert html =~ "Noirs"
    end

    test "a player card renders in Dutch", %{slug: slug} do
      html = "nl" |> asking() |> get(~p"/t/#{slug}/player/1") |> html_response(200)

      assert html =~ "Ronde per ronde"
      assert html =~ "Tegenstander"
    end

    test "the entry form renders in French", %{slug: slug} do
      html = "fr" |> asking() |> get(~p"/t/#{slug}/register") |> html_response(200)

      assert html =~ "Nom"
      assert html =~ "Envoyer l&#39;inscription"
    end

    test "a validation failure is answered in the reader's language", %{slug: slug} do
      html =
        "nl"
        |> asking()
        |> post(~p"/t/#{slug}/register", %{"registration" => %{"name" => "", "email" => ""}})
        |> html_response(422)

      assert html =~ "geef de naam op die je op de paringslijst wilt zien"
      assert html =~ "de arbiter heeft een adres nodig om je te bereiken"
    end

    # The two tests above pass on messages Ecto reports with no options worth
    # mentioning. A LENGTH failure is the other shape, and until 2026-09-12 it
    # was answered in English on this very page: `validate_length/3` attaches
    # Ecto's `count:` option whether or not the message it was given says
    # anything about a count, and `CoreComponents.translate_error/1` took that
    # option as permission to look the message up as a PLURAL - which a
    # singular msgid never answers. The catalogue was complete throughout, so
    # the "every message is translated" test below saw nothing wrong.
    test "and so is a length failure, which is looked up differently", %{slug: slug} do
      html =
        "fr"
        |> asking()
        |> post(~p"/t/#{slug}/register", %{
          "registration" => %{
            "name" => "A",
            "email" => "ilse@example.com",
            "club" => String.duplicate("c", 200)
          }
        })
        |> html_response(422)

      assert html =~ "un nom compte entre 2 et 100 caractères"
      assert html =~ "un nom de club compte au maximum 100 caractères"
      refute html =~ "a name is between 2 and 100 characters"
      refute html =~ "a club name is at most 100 characters"
    end

    test "a 404 is answered in the reader's language too", %{conn: conn} do
      html = conn |> put_req_header("accept-language", "fr") |> get(~p"/t/nope")

      assert html_response(html, 404) =~ "Introuvable"
    end
  end

  describe "the catalogues" do
    test "every message the site ships is translated, not merely marked for translation" do
      # `mix gettext.extract --merge` leaves a new message with an empty
      # msgstr, and an empty msgstr is not a missing feature: it is an
      # English sentence in the middle of a Dutch page, shipped, with nothing
      # to announce it but a reader noticing. English is exempt because there
      # the msgid IS the translation.
      for locale <- ~w(nl fr), domain <- ~w(default errors) do
        path = "priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po"

        untranslated =
          path
          |> Expo.PO.parse_file!()
          |> Map.fetch!(:messages)
          |> Enum.filter(&untranslated?/1)
          |> Enum.map(&IO.iodata_to_binary(&1.msgid))

        assert untranslated == [], "#{path} still says these in English: #{inspect(untranslated)}"
      end
    end

    test "and no message is left carrying gettext's guess" do
      # An empty msgstr is not the only way a wrong sentence ships, and it is
      # not the dangerous one. `mix gettext.extract --merge` also FILLS a new
      # message from an old one it thinks is similar and flags it `fuzzy` -
      # which is gettext saying "I made this up, check it".
      #
      # It happened here on 2026-09-10: the cross-table's "No rounds have
      # been published yet" was matched to the standings sentence and
      # pre-filled as "nog geen STAND gepubliceerd" / "Aucun CLASSEMENT". Both
      # are fluent, neither is empty, and both are about a different page.
      # The test above passes on all of them, which is exactly why this one
      # exists: the check for silence does not catch confident nonsense.
      #
      # The fix when this fails is to correct the translation and remove the
      # flag - never to remove the flag alone.
      for locale <- ~w(en nl fr), domain <- ~w(default errors) do
        path = "priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po"

        guessed =
          path
          |> Expo.PO.parse_file!()
          |> Map.fetch!(:messages)
          # `flags` is a list of flag LINES, each a list - `[["fuzzy"]]` - so
          # a bare `in` is always false and the check silently passes
          # everything. Caught by flagging a message on purpose and watching
          # this test not care.
          |> Enum.filter(&guessed?/1)
          |> Enum.map(&IO.iodata_to_binary(&1.msgid))

        assert guessed == [],
               "#{path} carries gettext's own guess for: #{inspect(guessed)} - " <>
                 "check each against the page it belongs to, then drop the fuzzy flag"
      end
    end
  end

  # Fuzzy AND actually saying something. A fuzzy flag on an EMPTY msgstr is
  # not a risk: nothing is rendered from it, the msgid is what shows, and in
  # the English catalogue that combination is ordinary - three entries had it
  # already. The danger is a guess that reads fluently and is about a
  # different page, which by definition is not blank.
  defp guessed?(message) do
    "fuzzy" in List.flatten(message.flags) and not untranslated?(message)
  end

  defp untranslated?(%Expo.Message.Singular{msgstr: msgstr}), do: blank?(msgstr)

  defp untranslated?(%Expo.Message.Plural{msgstr: forms}),
    do: forms |> Map.values() |> Enum.any?(&blank?/1)

  defp blank?(strings), do: strings |> IO.iodata_to_binary() |> String.trim() == ""

  describe "resolving, on its own" do
    test "the parameter wins, then the cookie, then the header" do
      assert Locale.resolve("fr", "nl", "en") == "fr"
      assert Locale.resolve(nil, "nl", "en") == "nl"
      assert Locale.resolve(nil, nil, "fr-BE") == "fr"
      assert Locale.resolve(nil, nil, nil) == "en"
    end

    test "anything unshippable is ignored rather than obeyed" do
      assert Locale.resolve("klingon", nil, "nl") == "nl"
      assert Locale.resolve(nil, "klingon", "fr") == "fr"
      assert Locale.resolve(nil, nil, "de,es") == "en"
    end

    test "nothing about a header can raise" do
      for junk <- [nil, "", ";", "q=1", "nl;q=", ["nl"], %{}, 42, "nl;q=1;q=2"] do
        assert Locale.resolve(nil, nil, junk) in Locale.codes()
      end
    end
  end
end
