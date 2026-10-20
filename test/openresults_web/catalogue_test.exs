defmodule OpenResultsWeb.CatalogueTest do
  @moduledoc """
  The catalogues themselves, checked the way a compiler would.

  `OpenResultsWeb.LocaleTest` already asks the two questions a reader would
  notice at once: is anything still in English, and is anything carrying
  gettext's own guess. Everything here is the layer under that - the ways a
  catalogue can be wrong while every message in it looks perfectly fine.

  Each one is a class of defect, not an instance. They were added after the
  translations audit of 2026-09-12, and the two that found something on the
  day they were written say so where they are.
  """
  use ExUnit.Case, async: true

  alias Expo.Message
  alias Expo.PO
  alias OpenResults.Registrations.Entry
  alias OpenResultsWeb.CoreComponents

  @locales ~w(en nl fr)
  @translated ~w(nl fr)
  @domains ~w(default errors)

  # The plural rule each locale's own header must declare. Not decoration:
  # this version of gettext PARSES `Plural-Forms` out of the PO file and
  # pluralises from it (`Expo.PluralForms` via `Gettext.Plural.plural_info/3`),
  # so a wrong header here is a wrong sentence on the page, not merely a
  # confused Poedit.
  #
  # French and Dutch genuinely differ, and on the count a results site
  # actually renders: at n = 0, `n != 1` is plural ("0 rondes") and `n > 1`
  # is singular ("0 ronde"). Dutch wants the first, French the second.
  @plural_rules %{
    "en" => "nplurals=2; plural=(n != 1);",
    "nl" => "nplurals=2; plural=(n != 1);",
    "fr" => "nplurals=2; plural=(n>1);"
  }

  # The three sentences this site renders through `raw/1` rather than letting
  # HEEx escape them - see `OpenResultsWeb.TournamentHTML.anchor/2` and the
  # two templates that call it. Every other message on the site is escaped on
  # its way out, so an `&` in it is a literal ampersand and nothing else; in
  # these three it is raw HTML, and `&`, `<` or `>` reaching the browser
  # unescaped is a malformed document rather than the sentence a translator
  # wrote.
  #
  # Listed by msgid rather than found by grepping the templates, so that a
  # fourth `raw/1` site added later fails to be covered loudly (the list stops
  # matching the templates) rather than quietly.
  @rendered_raw [
    "The details for %{name} are in the queue for the organisers of %{tournament}.",
    "The organisers read this queue on their own machine and decide who plays. You will not appear on the %{standings}, in a pairing, or anywhere else on this site until they have entered you and published a round - and if they need to ask you something first, they will use the address you gave.",
    "The running score stops at the first round whose result is not public - an unpublished round, a board that is not listed, or a game with no result yet. The arbiter's own total is on the %{standings}."
  ]

  describe "the catalogues against their template" do
    test "every locale carries exactly the messages the template does" do
      # `mix gettext.extract --merge` keeps these in step, and it is run from
      # a working tree that may have half a feature in it. A msgid in one
      # catalogue and not another is an English sentence on one page in one
      # language, which is precisely the shape nobody notices.
      for domain <- @domains do
        wanted = domain |> template() |> keys()

        for locale <- @locales do
          got = locale |> catalogue(domain) |> keys()

          assert MapSet.difference(wanted, got) |> MapSet.to_list() == [],
                 "#{locale}/#{domain}.po is missing messages the template has"

          assert MapSet.difference(got, wanted) |> MapSet.to_list() == [],
                 "#{locale}/#{domain}.po carries messages the template does not - " <>
                   "run `mix gettext.extract --merge`"
        end
      end
    end

    test "and carries each of them once" do
      for locale <- @locales, domain <- @domains do
        messages = locale |> catalogue(domain) |> messages()
        keys = Enum.map(messages, &Message.key/1)

        assert keys -- Enum.uniq(keys) == [],
               "#{locale}/#{domain}.po has the same msgid twice - gettext uses " <>
                 "whichever it compiled last"
      end
    end

    test "and nothing that has been retired" do
      # An obsolete entry (`#~`) is a translation for a msgid nothing calls
      # any more. Harmless to render and not harmless to keep: it is the
      # thing a translator spends an afternoon on before anybody notices the
      # page it belonged to is gone.
      for locale <- @locales, domain <- @domains do
        obsolete =
          locale
          |> catalogue(domain)
          |> Map.fetch!(:messages)
          |> Enum.filter(& &1.obsolete)
          |> Enum.map(&text(&1.msgid))

        assert obsolete == [], "#{locale}/#{domain}.po still carries retired messages"
      end
    end

    test "and points only at source that exists" do
      # A reference to a file or a line that has moved is not a runtime bug;
      # it is how a translator loses the ability to see what they are
      # translating. Checked against the template only - the PO files carry
      # the same references, merged from it.
      for domain <- @domains do
        for message <- domain |> template() |> messages(),
            line <- message.references,
            reference <- line do
          {file, number} =
            case reference do
              {file, number} -> {file, number}
              file when is_binary(file) -> {file, nil}
            end

          assert File.exists?(file),
                 "#{domain}.pot points at #{file}, which is not in the tree"

          if number do
            lines = file |> File.read!() |> String.split("\n") |> length()

            assert number <= lines,
                   "#{domain}.pot points at #{file}:#{number}, past the end of a #{lines}-line file"
          end
        end
      end
    end
  end

  describe "bindings" do
    test "no translation asks for a value its caller never passes" do
      # The failure this prevents is loud in the log and invisible on the
      # page: gettext logs `missing Gettext bindings` at :error and renders
      # the placeholder as literal text. On this site every page is a cached
      # public page polled every twenty seconds by every phone in the hall,
      # so one such message is a production log full of them.
      #
      # A translation may also DROP a placeholder the msgid has - a French
      # sentence that never says the tournament's name - which gettext is
      # perfectly happy with and a reader is not.
      for locale <- @translated,
          domain <- @domains,
          message <- messages(catalogue(locale, domain)) do
        case message do
          %Expo.Message.Singular{msgstr: msgstr} ->
            assert_bindings(locale, domain, text(message.msgid), text(msgstr))

          %Expo.Message.Plural{msgstr: forms} ->
            # Either msgid's placeholders are fair game in any form, since a
            # plural is one sentence written twice.
            allowed =
              MapSet.union(bindings(text(message.msgid)), bindings(text(message.msgid_plural)))

            for {index, form} <- forms do
              got = bindings(text(form))

              assert MapSet.subset?(got, allowed),
                     "#{locale}/#{domain} plural form #{index} of #{inspect(text(message.msgid))} " <>
                       "asks for #{inspect(MapSet.to_list(MapSet.difference(got, allowed)))}"

              assert MapSet.subset?(
                       MapSet.intersection(
                         bindings(text(message.msgid)),
                         bindings(text(message.msgid_plural))
                       ),
                       got
                     ),
                     "#{locale}/#{domain} plural form #{index} of #{inspect(text(message.msgid))} " <>
                       "drops a value the sentence is about"
            end
        end
      end
    end
  end

  describe "escaping" do
    test "the sentences rendered as raw HTML hold no markup in any language" do
      for msgid <- @rendered_raw do
        for locale <- @locales do
          message = find(catalogue(locale, "default"), msgid)

          assert message,
                 "#{locale}/default.po has no entry for a sentence this site renders raw - " <>
                   "if it was reworded, reword @rendered_raw with it"

          for character <- ["&", "<", ">"] do
            refute String.contains?(text(message.msgstr), character),
                   "#{locale}/default.po writes #{character} in a sentence rendered through " <>
                     "raw/1, where it reaches the browser as markup: #{inspect(msgid)}"
          end
        end
      end
    end

    test "and no message anywhere carries a pre-escaped entity" do
      # The other half of the same mistake, on the 205 messages that ARE
      # escaped by HEEx: `&amp;` written in a catalogue is shown to the
      # reader as the five characters `&amp;`. The sibling repo shipped this
      # twice before it was written down.
      for locale <- @locales,
          domain <- @domains,
          message <- messages(catalogue(locale, domain)) do
        for string <- strings(message) do
          refute string =~ ~r/&(amp|lt|gt|quot|nbsp|#\d+|#x[0-9a-fA-F]+);/,
                 "#{locale}/#{domain} writes an HTML entity in #{inspect(string)} - " <>
                   "HEEx escapes these, so it renders as the entity rather than the character"
        end
      end
    end
  end

  describe "plurals" do
    test "each locale declares its own rule, and it is the right one" do
      for locale <- @locales, domain <- @domains do
        header =
          locale
          |> catalogue(domain)
          |> Expo.Messages.get_header("Plural-Forms")
          |> text()

        assert header == @plural_rules[locale],
               "#{locale}/#{domain}.po declares #{inspect(header)}"
      end
    end

    test "and every form of every plural is filled" do
      # A blank French plural is a blank on the page, not a fallback to
      # English: gettext found the message, so it has an answer.
      for locale <- @translated,
          domain <- @domains,
          message <- messages(catalogue(locale, domain)) do
        case message do
          %Expo.Message.Plural{msgstr: forms} ->
            assert map_size(forms) == 2,
                   "#{locale}/#{domain} gives #{map_size(forms)} forms for " <>
                     "#{inspect(text(message.msgid))}"

            for {index, form} <- forms do
              refute String.trim(text(form)) == "",
                     "#{locale}/#{domain} leaves form #{index} of " <>
                       "#{inspect(text(message.msgid))} blank"
            end

          %Expo.Message.Singular{} ->
            :ok
        end
      end
    end
  end

  describe "the entry form's own messages" do
    # These are the one set of strings on the site that are NOT extracted -
    # they are `:message` options on the changeset in
    # `OpenResults.Registrations.Entry`, carried by Ecto and looked up in the
    # `errors` catalogue by `CoreComponents.translate_error/1`. Nothing
    # compiles them together, so nothing but this notices when the two halves
    # drift.

    test "every message the changeset can produce is answered in Dutch and French" do
      # This is the test that found the bug it was written for. Three
      # messages - the `validate_length` ones on name, email and club -
      # translated perfectly when looked up by hand and rendered in ENGLISH
      # on a French page, because `translate_error/1` routed anything
      # carrying Ecto's `count:` option through `dngettext/6` and a singular
      # msgid is a miss there. See that function for the whole story.
      #
      # Asserting "different from the English" rather than "equal to some
      # expected French" deliberately: the point is that the catalogue was
      # reached at all.
      for {locale, changeset} <- for(l <- @translated, do: {l, invalid_entry()}) do
        Gettext.put_locale(OpenResultsWeb.Gettext, locale)

        for {field, error} <- changeset.errors do
          {msgid, _opts} = error
          translated = CoreComponents.translate_error(error)

          refute translated == msgid,
                 "#{locale}: the entry form answers #{field} in English - #{inspect(msgid)}"
        end
      end
    after
      Gettext.put_locale(OpenResultsWeb.Gettext, "en")
    end

    test "and the interpolated limits still match the msgids they were copied into" do
      # Two messages name their own bounds by interpolating a module
      # attribute - `#{@rating_range.first} and #{@rating_range.last}` - so
      # the msgid in `errors.pot` has today's numbers frozen into it. Widen
      # either range and every translation of that sentence silently falls
      # back to English, with no extractor to say so.
      wanted = "errors" |> template() |> keys()

      for message <- bounded_messages() do
        assert MapSet.member?(wanted, {"", message}),
               "a changeset message has drifted from its msgid: #{inspect(message)} - " <>
                 "a range constant changed, so update errors.pot and all three catalogues"
      end
    end
  end

  # Every message the changeset writes by hand that interpolates a constant.
  # Produced from the changeset itself, not retyped, so it cannot agree with
  # a stale copy of the code.
  defp bounded_messages do
    %{"birth_year" => 1, "rating" => -1}
    |> Entry.changeset()
    |> Map.fetch!(:errors)
    |> Enum.filter(fn {field, _} -> field in [:birth_year, :rating] end)
    |> Enum.map(fn {_field, {msgid, _opts}} -> msgid end)
  end

  # One entry that fails every message worth checking at once: required,
  # length, format, inclusion and number. `requested_byes` is deliberately
  # absent - its message is built at runtime from the tournament's own round
  # list and cannot be in a catalogue, which `errors.pot` says at the top.
  defp invalid_entry do
    Entry.changeset(%{
      "name" => "A",
      "email" => String.duplicate("a", 300) <> "@b.c",
      "club" => String.duplicate("c", 200),
      "birth_year" => 1,
      "rating" => -1,
      "title" => "XX",
      "federation" => "BELGIUM",
      "fide_id" => 0,
      "national_id" => "12 34"
    })
  end

  defp assert_bindings(locale, domain, msgid, msgstr) do
    if String.trim(msgstr) != "" do
      assert bindings(msgstr) == bindings(msgid),
             "#{locale}/#{domain} translates #{inspect(msgid)} as #{inspect(msgstr)}, " <>
               "which asks for #{inspect(MapSet.to_list(bindings(msgstr)))} rather than " <>
               "#{inspect(MapSet.to_list(bindings(msgid)))}"
    end
  end

  defp bindings(string),
    do: ~r/%\{[^}]*\}/ |> Regex.scan(string) |> List.flatten() |> MapSet.new()

  defp catalogue(locale, domain),
    do: PO.parse_file!("priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po")

  defp template(domain), do: PO.parse_file!("priv/gettext/#{domain}.pot")

  # The header entry carries the file's metadata under an empty msgid and is
  # not a message anybody translates.
  defp messages(%Expo.Messages{messages: messages}) do
    Enum.reject(messages, &(&1.obsolete or text(&1.msgid) == ""))
  end

  defp keys(catalogue), do: catalogue |> messages() |> Enum.map(&Message.key/1) |> MapSet.new()

  defp find(catalogue, msgid),
    do: catalogue |> messages() |> Enum.find(&(text(&1.msgid) == msgid))

  defp strings(%Expo.Message.Singular{msgid: msgid, msgstr: msgstr}),
    do: [text(msgid), text(msgstr)]

  defp strings(%Expo.Message.Plural{msgid: msgid, msgid_plural: plural, msgstr: forms}),
    do: [text(msgid), text(plural) | forms |> Map.values() |> Enum.map(&text/1)]

  defp text(iodata), do: IO.iodata_to_binary(iodata)
end
