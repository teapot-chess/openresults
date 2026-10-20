defmodule OpenResultsWeb.Tournament do
  @moduledoc """
  A published snapshot, read as a tournament.

  The only module that knows the shape of the document in
  `docs/snapshot-schema.md`. Everything here reads; nothing here decides. The
  arbiter's machine applied the tiebreaks, ordered the placings and set the
  bye values before it built the payload, so this app renders what it was
  given even where a number looks wrong. A server that corrected the arbiter
  would put the hall and the public page into disagreement, which is the one
  failure the contract exists to prevent.

  Every accessor tolerates an absent key. A payload is allowed to be older
  than the server reading it, so a missing `standings`, a round without
  `byes`, or a player without a rating is a tournament that has not got there
  yet rather than an error. Fields nobody here recognises are simply not
  looked at, which is the same rule the ingest side follows.

  Two things here are words rather than data - a round's heading and the
  fallback name for a tournament that published without one - and both are
  translated. They read as data because they are built from the payload, but
  a Dutch page whose only English left is the word above the pairings is a
  page that looks broken rather than bilingual.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

  # Every result token the contract carries, and the points each seat scored,
  # as `{white, black}`.
  #
  # The token is read rather than interpreted: `"1-0"` states in its own two
  # halves what each side got, and so does every other token in the
  # vocabulary. Picking the half that belongs to a seat is not arithmetic an
  # arbiter could disagree with, which is what makes the running score on a
  # player card defensible when the contract deliberately carries no per-game
  # points.
  #
  # The legacy `+--` and `--+` spellings are deliberately absent. The publish
  # path normalises them to `1-0FF` and `0-1FF`, so accepting them here would
  # document a vocabulary that no longer travels.
  @result_points %{
    "1-0" => {1.0, 0.0},
    "0-1" => {0.0, 1.0},
    "1/2-1/2" => {0.5, 0.5},
    "1-0U" => {1.0, 0.0},
    "0-1U" => {0.0, 1.0},
    "1/2-1/2U" => {0.5, 0.5},
    "1/2-0" => {0.5, 0.0},
    "0-1/2" => {0.0, 0.5},
    "0-0" => {0.0, 0.0},
    "1-0FF" => {1.0, 0.0},
    "0-1FF" => {0.0, 1.0},
    "0-0FF" => {0.0, 0.0}
  }

  @doc """
  The `tournament` object, or an empty one.
  """
  def info(payload), do: object(payload, "tournament")

  @doc """
  Whether this tournament belongs in the front-page list.

  Absent means listed, which is what publishing meant before there was a
  choice. An arbiter unlists an event to hand out its link rather than
  advertise it - it stays perfectly readable to anyone holding the address,
  and the arbiter's own settings page says so in as many words, because
  reading "unlisted" as "private" is how somebody publishes an event they
  meant to keep off the web.
  """
  def listed?(payload) do
    case Map.get(info(payload), "listed") do
      false -> false
      _listed_or_unstated -> true
    end
  end

  @doc """
  Whether the arbiter allows `key` to be shown - `"rating"`, `"club"`,
  `"federation"`, `"title"`, `"category"`, `"tiebreaks"`, `"player_cards"`.

  **Absent means shown**, in every direction: a payload from before the
  field existed, a key this server knows that the arbiter's app has never
  heard of, and a key the arbiter's app sends that this server does not
  recognise. All three are the same answer, and it is the same answer this
  server gave before any of it existed.

  The failure directions are not symmetric. Showing a column an arbiter
  meant to hide is visible to them and fixed in one click; hiding one they
  meant to show is invisible from their side - their own screens look right
  - and surfaces as somebody in the hall asking where the ratings went.

  Note this is a display rule, not an access rule. It decides what a page
  renders. Nothing here is a substitute for not publishing data that should
  not leave the arbiter's machine.
  """
  def show?(payload, key) do
    case payload |> info() |> Map.get("display") do
      %{} = display ->
        case Map.get(display, key) do
          false -> false
          _shown_or_unstated -> true
        end

      _absent_or_junk ->
        true
    end
  end

  @doc """
  Whether a flag is drawn beside a federation code.

  **Absent means off**, unlike `show?/2`: `display.flags` must be `true`. A
  snapshot from an arbiter's app that predates the key has not asked for
  pictures on its pages, and a page that looked one way yesterday should
  not grow them because this server was upgraded. Also off wherever the
  federation itself is hidden - there is no code to draw a flag for. See
  `OpenResultsWeb.Flags`.
  """
  def flags?(payload) do
    case payload |> info() |> Map.get("display") do
      %{"flags" => true} -> show?(payload, "federation")
      _absent_off_or_junk -> false
    end
  end

  @doc """
  Whether the players carry a sex, and so whether a Sex column is drawn.

  Asked of the players themselves, not of a display tick: OpenPairings sends
  `players[].sex` ("M" or "F") only when the arbiter turned "Sex" on, which
  is off by default, so absent means no column - and a snapshot from before
  the field existed renders exactly as it did.
  """
  def sex?(payload), do: Enum.any?(players(payload), &(Map.get(&1, "sex") in ["M", "F"]))

  @doc """
  Whether the cross-table page is offered at all.

  Two ticks, and both have to be on.

  `crosstable` is the page's own switch, and it does not exist in any
  snapshot published before the page did - so absent means shown, like every
  other key here, and an arbiter whose app has never heard of it gets the
  page.

  `pairings` is the one that is not obvious. The cross-table is the round
  pages transposed: every board, every result, every colour, all of it read
  out of the same `rounds[]` the round pages read. An arbiter who withheld
  their pairings and then found all of them on a grid one click away would
  have been handed a page that quietly undoes their own setting.
  """
  def crosstable?(payload), do: show?(payload, "pairings") and show?(payload, "crosstable")

  @doc """
  Whether the arbiter says this tournament has live boards -
  `tournament.live_boards: true`, which OpenPairings sends when the arbiter
  ticks "Live boards" in the publishing options. The pages link to `/t/:slug/live` only on this word, and
  on an EXPLICIT `true`: those pages are cached per snapshot, so a link that
  appeared when the first game was reported would be stale in the cache until
  the next publish. The live pages themselves work with or without it, for
  any tournament that has published.
  """
  def live_boards?(payload), do: Map.get(info(payload), "live_boards") == true

  @doc """
  Whether the arbiter is accepting entries for this tournament.

  **An absent field means open**, which is the one place in this module where
  the tolerant default is not merely convenient but load-bearing.

  `registration_open` was added to the contract on 2026-08-29, when the
  arbiter's app stopped serving its own entry form and this became the only
  one. Every snapshot published before that date is silent on the question,
  and this server accepted entries for all of them - so reading silence as
  "open" is what those tournaments already do, and reading it as "closed"
  would shut every one of them the moment this deployed, without a word to
  the arbiter and without anything in the UI to explain it.

  The failure directions are not symmetric. An entry that should not have
  been taken lands in a queue an arbiter reads and rejects; a form that is
  shut when it should be open turns a real person away and tells nobody. So
  the tolerant reading is also the safe one.
  """
  def registration_open?(payload) do
    case Map.get(info(payload), "registration_open") do
      false -> false
      _open_or_unstated -> true
    end
  end

  @doc """
  Whether the tournament's pages advertise the entry form.

  Only on an explicit `registration_open: true`. `registration_open?/1` reads
  silence as open, and that is right for the form itself - a snapshot
  published before the field existed took entries, and shutting it silently
  would turn people away. It is wrong for a link: a tournament whose last
  snapshot predates the field was published by an arbiter who never saw an
  entry-form switch, and a link would invite entries into a queue nobody
  knows to read. Every arbiter's app since 2026-08-29 sends the field, so an
  arbiter who wants entries has said so.
  """
  def entry_link?(payload), do: Map.get(info(payload), "registration_open") == true

  @doc """
  The `tournament.registration` object - the form's window, the size of the
  field and whether the entry list is public - or an empty one.

  Added to the contract on 2026-09-30; see `docs/snapshot-schema.md`, "The
  entry form's own settings". Every key is optional and absent means no
  restriction, the same reading `registration_open?/1` gives silence.
  """
  def registration(payload), do: object(info(payload), "registration")

  @doc """
  Whether the entry form takes an entry right now, and if not, why not.

  `:open`, or the first reason it is shut, in the order a person at the form
  would want to hear them: the arbiter closed it (`:closed`), it has not
  opened yet (`:not_yet`), its closing time has passed (`:ended`), or the
  field is full (`:full`).

  `now` is the server's clock, so the window opens and shuts on time whether
  or not the arbiter's machine is online to republish. `queued_since` is the
  number of entries this server received after the snapshot was stored:
  they are not in the snapshot's `taken` yet, and leaving them out would let
  a laptop that is closed for the evening be oversubscribed by the morning.
  """
  @spec registration_state(map(), DateTime.t(), non_neg_integer()) ::
          :open | :closed | :not_yet | :ended | :full
  def registration_state(payload, %DateTime{} = now, queued_since \\ 0) do
    settings = registration(payload)
    opens_at = instant(settings, "opens_at")
    closes_at = instant(settings, "closes_at")

    cond do
      not registration_open?(payload) -> :closed
      opens_at && DateTime.compare(now, opens_at) == :lt -> :not_yet
      closes_at && DateTime.compare(now, closes_at) != :lt -> :ended
      full?(payload, queued_since) -> :full
      true -> :open
    end
  end

  @doc "When the form opens, if the arbiter set a time."
  def registration_opens_at(payload), do: instant(registration(payload), "opens_at")

  @doc "When the form closes, if the arbiter set a time."
  def registration_closes_at(payload), do: instant(registration(payload), "closes_at")

  @doc """
  The size of the field, if the arbiter capped it.

  A value that is not a positive whole number is read as no cap: an arbiter's
  app that sent `0` or `"60"` has said nothing this server can act on, and
  closing a form over a malformed number would turn people away for a typo.
  """
  def max_players(payload) do
    case Map.get(registration(payload), "max_players") do
      max when is_integer(max) and max > 0 -> max
      _absent_or_malformed -> nil
    end
  end

  @doc """
  Places taken: the entry list plus the entries waiting for the arbiter, as
  the arbiter's machine counted them, plus `queued_since`.

  Falls back to the number of published players when the snapshot does not
  say - a count it certainly has.
  """
  def places_taken(payload, queued_since \\ 0) do
    base =
      case Map.get(registration(payload), "taken") do
        taken when is_integer(taken) and taken >= 0 -> taken
        _absent_or_malformed -> length(players(payload))
      end

    base + queued_since
  end

  @doc """
  Whether the form page may list who has entered. **Absent means no** - the
  one key in this object read that way, because it decides whether a page
  shows names the arbiter never chose to put there; see
  `docs/snapshot-schema.md`.
  """
  def entry_list_public?(payload), do: Map.get(registration(payload), "list_public") == true

  @max_pending_names 200

  @doc """
  The names of entries still waiting for the arbiter's decision, for the
  public entry list - or `[]`.

  Decided 2026-10-18: waiting entries may be listed by name, marked
  unconfirmed, but only where the arbiter has turned the public list on, and
  only the names the arbiter's machine put in `tournament.registration.pending`.
  That list is the arbiter's own curation - a discarded entry is simply absent
  from the next snapshot - so this server holds no list of its own and has
  nothing to keep in step. The names were typed by strangers, so each is
  re-cleaned here as well (control characters out, whitespace collapsed, 100
  characters at most, at most #{@max_pending_names} of them) and the page
  escapes them like every other string it prints.
  """
  @spec pending_entrants(map()) :: [String.t()]
  def pending_entrants(payload) do
    if entry_list_public?(payload) do
      case Map.get(registration(payload), "pending") do
        entries when is_list(entries) ->
          entries
          |> Enum.map(&pending_name/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(@max_pending_names)

        _absent_or_malformed ->
          []
      end
    else
      []
    end
  end

  defp pending_name(%{"name" => name}) when is_binary(name) do
    case name
         |> String.replace(~r/[[:cntrl:]]+/u, " ")
         |> String.replace(~r/\s+/u, " ")
         |> String.trim()
         |> String.slice(0, 100) do
      "" -> nil
      clean -> clean
    end
  end

  defp pending_name(_other), do: nil

  @doc """
  What the form says it costs: `%{amount: "12.50", currency: "EUR", note: ...}`
  with any part nil, or nil when the arbiter stated nothing.

  Statement only. Nothing on this site takes payment. Every part is read
  defensively because it is printed on a public page: an amount must look
  like one, a currency is three capital letters, a note is stripped of
  control characters and cut at 120 characters. A part that fails is
  dropped rather than printed.
  """
  @spec entry_fee(map()) ::
          %{amount: String.t() | nil, currency: String.t() | nil, note: String.t() | nil} | nil
  def entry_fee(payload) do
    fee = object(registration(payload), "fee")

    amount =
      case Map.get(fee, "amount") do
        value when is_binary(value) -> if value =~ ~r/\A\d{1,6}(\.\d{1,2})?\z/, do: value
        _other -> nil
      end

    currency =
      case Map.get(fee, "currency") do
        value when is_binary(value) -> if value =~ ~r/\A[A-Z]{3}\z/, do: value
        _other -> nil
      end

    note =
      case Map.get(fee, "note") do
        value when is_binary(value) ->
          case value
               |> String.replace(~r/[[:cntrl:]]+/u, " ")
               |> String.replace(~r/\s+/u, " ")
               |> String.trim()
               |> String.slice(0, 120) do
            "" -> nil
            clean -> clean
          end

        _other ->
          nil
      end

    if amount || note, do: %{amount: amount, currency: amount && currency, note: note}
  end

  defp full?(payload, queued_since) do
    case max_players(payload) do
      nil -> false
      max -> places_taken(payload, queued_since) >= max
    end
  end

  defp instant(map, key) do
    with value when is_binary(value) <- Map.get(map, key),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      datetime
    else
      _absent_or_unparseable -> nil
    end
  end

  @doc """
  The tournament's display name, falling back to its slug.
  """
  def name(payload) do
    info = info(payload)
    string(info, "name") || string(info, "slug") || gettext("Tournament")
  end

  @doc """
  The pairing system: `"swiss"`, `"roundrobin"`, `"keizer"`, or whatever a
  newer client sent.
  """
  def system(payload), do: string(info(payload), "system")

  @doc """
  Whether the standings carry Keizer's columns instead of points and
  tiebreaks.

  Keyed off `system` rather than off which keys happen to be present on a row,
  because a row that is merely missing `tiebreaks` is an incomplete swiss row,
  not a Keizer one.
  """
  def keizer?(payload), do: system(payload) == "keizer"

  @doc """
  How many rounds the tournament has, published or not.
  """
  # Clamped, because this number comes from the payload and the payload comes
  # from whoever holds the ingest token. `round_slots/1` materialises
  # `1..rounds_count` and the masthead walks it, so a mistyped 1_000_000 costs
  # every anonymous reader seconds of CPU on every request, forever, from one
  # POST. Measured before clamping: 3.8 s for standings and 10.3 s for a
  # player card at a million.
  #
  # 100 is past any real event - the longest FIDE-rated Swiss on record is
  # nowhere near it - so a count above it is a typo or an attack, and either
  # way the honest answer is to ignore it rather than to serve it slowly.
  @max_rounds 100

  def rounds_count(payload) do
    case Map.get(info(payload), "rounds_count") do
      count when is_integer(count) and count >= 0 and count <= @max_rounds -> count
      _absent_or_implausible -> 0
    end
  end

  @doc """
  The rounds present in the payload, in number order.

  Published rounds and no others: a round the arbiter withheld was never sent.
  """
  def rounds(payload) do
    payload
    |> list("rounds")
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&number_of/1)
  end

  @doc """
  The numbers of the published rounds.
  """
  def round_numbers(payload) do
    payload
    |> rounds()
    |> Enum.map(&number_of/1)
    |> Enum.filter(&is_integer/1)
  end

  @doc """
  Every round the tournament has, published or not, in order.

  The union of `1..rounds_count` and whatever `rounds` actually contains, so a
  round arriving beyond the declared count still gets a slot rather than
  disappearing. What this is for is showing the gaps: a navigation strip that
  listed only the published rounds would make a withheld round look like a
  tournament that is one round shorter.
  """
  def round_slots(payload) do
    Enum.sort(Enum.uniq(Enum.to_list(1..rounds_count(payload)//1) ++ round_numbers(payload)))
  end

  @doc """
  Where a tournament sits in its own life cycle: `:live`, `:upcoming` or
  `:finished`.

  For the front page, to group a long season's worth of events the way a
  spectator actually thinks about them rather than as one undifferentiated
  list. `today` is `Date.utc_today/0` by default and an explicit argument
  for tests - the one place in this module the wall clock enters at all.

  ## The rule, since the payload cannot state this outright

  Nothing here is sent as a single field; it is derived, in this order, from
  fields the contract already carries:

    1. **`:finished`** - the published rounds reach `rounds_count` (every
       round is in), OR `end_date` has already passed. Checked first: a
       calendar that says an event is over outranks everything else, even a
       `rounds_count` the arbiter never kept current.
    2. **`:upcoming`** - nothing has been published yet, AND `start_date` is
       either absent or still in the future.
    3. **`:live`** - everything else. The default for a tournament actually
       being played, and for one this server simply cannot place with
       confidence.

  ## The judgement calls, stated so they can be revisited

  A tournament with rounds published but no `rounds_count` (or one lower
  than what has actually been posted - a mistyped total) can never read as
  `:finished` by rule 1 alone; only a past `end_date` can close it. Silence
  reads as still running rather than as finished, because a spectator
  finding a live event mislabelled "finished" is a worse failure than the
  reverse.

  A tournament with NEITHER a published round NOR any date at all reads as
  `:upcoming` rather than `:live` - the only reading available when nothing
  the contract carries says otherwise, and the one that puts an entered but
  not-yet-started event where a spectator would expect to find it rather
  than beside events actually being played.
  """
  @spec status(map(), Date.t()) :: :live | :upcoming | :finished
  def status(payload, today \\ Date.utc_today()) do
    cond do
      finished?(payload, today) -> :finished
      upcoming?(payload, today) -> :upcoming
      true -> :live
    end
  end

  defp finished?(payload, today) do
    all_rounds_in?(payload) or past_end_date?(payload, today)
  end

  # Every round published AND its results public. A round whose results the
  # arbiter is still holding back is not over as far as this site can say,
  # however many rounds have been paired. The calendar rule beside this is
  # left alone: an event whose end date has passed is finished even with a
  # round still withheld, for the reason the doc above gives for dates
  # outranking a `rounds_count` nobody kept current.
  #
  # And every board of them decided (or postponed, which is decided later and
  # elsewhere). A round robin publishes all its rounds on day one, so
  # "everything is published" alone called a tournament finished before its
  # first move, while the same page announced results coming in.
  defp all_rounds_in?(payload) do
    all_rounds_published?(payload) and withheld_result_rounds(payload) == [] and
      not Enum.any?(live_rounds(payload), &(number_of(&1) <= rounds_count(payload)))
  end

  # Every round from 1 to `rounds_count`, published - not merely a published
  # round NUMBERED `rounds_count` or higher. The swiss fixture this repo
  # tests against is the reason this distinction exists at all: round 4 is
  # withheld while round 5 is already published, `rounds_count` is 5, and
  # the standings sit "after round 3" - a tournament plainly still running,
  # which "the highest published number reached the total" alone would have
  # called finished.
  defp all_rounds_published?(payload) do
    count = rounds_count(payload)
    count > 0 and MapSet.subset?(MapSet.new(1..count), MapSet.new(round_numbers(payload)))
  end

  defp past_end_date?(payload, today) do
    case parse_date(string(info(payload), "end_date")) do
      {:ok, date} -> Date.compare(date, today) == :lt
      :error -> false
    end
  end

  # Nothing published, or - a round robin's whole schedule out in advance -
  # published without a single result yet.
  defp upcoming?(payload, today) do
    (round_numbers(payload) == [] or no_results?(payload)) and not started_by?(payload, today)
  end

  defp no_results?(payload) do
    not Enum.any?(rounds(payload), fn round ->
      Enum.any?(boards(round), &is_binary(Map.get(&1, "result")))
    end)
  end

  # Absent means NOT known to have started - the safe reading for
  # `upcoming?`, which is the whole point of checking this rather than
  # assuming a silent tournament is already under way.
  defp started_by?(payload, today) do
    case parse_date(string(info(payload), "start_date")) do
      {:ok, date} -> Date.compare(date, today) != :gt
      :error -> false
    end
  end

  defp parse_date(nil), do: :error

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Round `number`, or `nil` if it is not in the payload.

  `nil` is the whole withholding rule: an unpublished round is absent from the
  document, so there is nothing to filter and nothing to leak. The caller's
  job is to turn it into a 404 rather than an empty page.
  """
  def round(payload, number) do
    Enum.find(rounds(payload), &(number_of(&1) == number))
  end

  @doc """
  Every round keyed by its number, for callers that look up more than one.

  `round/2` re-filters and re-SORTS the whole list on each call, which is
  fine once and quadratic in a loop - and the masthead and the player card
  both loop over every slot. Building the index once turns that back into one
  pass.
  """
  def rounds_by_number(payload) do
    Map.new(rounds(payload), &{number_of(&1), &1})
  end

  @doc """
  A round's boards, in board order.
  """
  def boards(round), do: round |> list("boards") |> Enum.filter(&is_map/1)

  @doc """
  Whether a round's results are public - `rounds[].results_public`.

  `false` means the arbiter has published the round's pairings and not yet
  its results: every board arrives with `result: null` because the results
  were withheld, not because none were entered, and the pages say so once
  instead of a column of unreported games.

  **Absent means true.** An OpenPairings that predates the switch sent every
  result it had, so a round without the key is a round whose results are
  public. Anything other than a literal `false` reads the same way, for the
  same reason `registration_open` reads silence as open.
  """
  def results_public?(round) when is_map(round), do: Map.get(round, "results_public") != false
  def results_public?(_not_a_round), do: true

  @doc """
  The numbers of the published rounds whose results are withheld, in order.
  """
  def withheld_result_rounds(payload) do
    payload
    |> rounds()
    |> Enum.reject(&results_public?/1)
    |> Enum.map(&number_of/1)
    |> Enum.filter(&is_integer/1)
  end

  @doc """
  How far a round's results have come in, as `{reported, total}` over its
  boards: a board with any result token counts as reported. Counting, never
  calculating - byes are not boards and are not counted.
  """
  def results_progress(round) do
    boards = boards(round)
    {Enum.count(boards, &is_binary(Map.get(&1, "result"))), length(boards)}
  end

  @doc """
  Whether a round is live: its results are public and at least one of its
  boards has no result yet and is not postponed. A withheld round is never
  live - nothing about its results is public, including how many are in.

  A postponed game (`postponed?/1`) is left out on purpose. It has no
  result and will not have one for days or weeks, and counting it would
  keep its round "Live" - and the page polling fast for it - until the two
  players finally sit down, long after everything else in the round is in.
  """
  def live_round?(round) do
    results_public?(round) and
      Enum.any?(boards(round), &(not is_binary(Map.get(&1, "result")) and not outstanding?(&1)))
  end

  @doc """
  Whether a board is a postponed game still to be played -
  `boards[].postponed` in `docs/snapshot-schema.md`.

  Only a literal `true` counts, and only on a board with no result: the
  flag is present exactly while the game is still to be played, so a board
  that somehow carries both is read by its result, which is the thing that
  actually happened.
  """
  def postponed?(board) when is_map(board),
    do: Map.get(board, "postponed") == true and not is_binary(Map.get(board, "result"))

  def postponed?(_not_a_board), do: false

  @doc """
  Whether a board is a pending game - `boards[].pending` in
  `docs/snapshot-schema.md`: a round-robin board nobody has entered, in a
  round the tournament has since moved past, which OpenPairings' standings
  count until its result is in. Not a postponed game - nobody postponed it,
  and it may have been played and simply not typed in - so it is worded
  differently ("Result not yet in"), and otherwise read exactly like one.

  Same rule as `postponed?/1`: a literal `true`, on a board with no result.
  """
  def pending?(board) when is_map(board),
    do: Map.get(board, "pending") == true and not is_binary(Map.get(board, "result"))

  def pending?(_not_a_board), do: false

  @doc """
  A game the standings count before it has a result: `postponed?/1` or
  `pending?/1`. What every sum, valuation and "is this round still live"
  check asks; only the wording tells the two apart.
  """
  def outstanding?(board), do: postponed?(board) or pending?(board)

  @doc """
  The date the two players agreed to play a postponed game, as the ISO string
  it arrived as, or `nil` - absent, not postponed, or not a string. Not a
  deadline: the arbiter enters it when the players have fixed one.
  """
  def postponed_date(board) do
    if postponed?(board), do: string(board, "postponed_date")
  end

  @doc """
  How many of a team match's boards are postponed games still to be played -
  `matches[].postponed_boards`. `0` when absent or not a positive integer.
  While it is above zero the match's `game_points` and `match_points` are
  provisional: OpenPairings counts each postponed board as a draw until it is
  played. Neither is recomputed here.
  """
  def match_postponed_boards(match) when is_map(match) do
    case Map.get(match, "postponed_boards") do
      n when is_integer(n) and n > 0 -> n
      _absent_or_junk -> 0
    end
  end

  def match_postponed_boards(_not_a_match), do: 0

  @doc """
  Whether the published standings are provisional because a game in the
  rounds they cover is still to come, as `{provisional?, count}` -
  `standings.provisional`, and `standings.pending_games` (every such game,
  postponed or pending) or, from an older publisher, `standings.postponed_games`.
  `count` is `nil` when the flag arrives without a usable number.
  """
  def standings_provisional(payload) do
    standings = standings(payload)

    count =
      positive(Map.get(standings, "pending_games")) ||
        positive(Map.get(standings, "postponed_games"))

    {Map.get(standings, "provisional") == true, count}
  end

  @doc """
  Whether any of the games `standings_provisional/1` counts is a pending
  board rather than a postponed game - `pending_games` above
  `postponed_games` - so the line above the table must not call them all
  postponed. False for an older snapshot, which only knew postponed games.
  """
  def standings_unreported?(payload) do
    standings = standings(payload)

    case positive(Map.get(standings, "pending_games")) do
      nil -> false
      pending -> pending > (positive(Map.get(standings, "postponed_games")) || 0)
    end
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_absent_or_junk), do: nil

  @doc """
  How the postponed games the standings count are valued, from
  `boards[].postponed_as` on the postponed boards in the rounds the standings
  cover: `:draw` when every seat of every such board is a draw (what the
  standings note has always said), `{:uniform, pair}` when every board has
  the same two valuations (`pair` sorted, e.g. `["loss", "win"]`), `:mixed`
  when the boards differ, and `:unknown` when it cannot be said - an older
  snapshot without `postponed_as`, or no postponed board in those rounds.
  """
  def postponed_valuation(payload) do
    covered = after_round(payload)

    pairs =
      for round <- rounds(payload),
          is_integer(covered) and number_of(round) <= covered,
          results_public?(round),
          board <- boards(round),
          outstanding?(board),
          do: valuation_pair(board)

    cond do
      pairs == [] or :unknown in pairs -> :unknown
      Enum.all?(pairs, &(&1 == ["draw", "draw"])) -> :draw
      match?([_], Enum.uniq(pairs)) -> {:uniform, hd(pairs)}
      true -> :mixed
    end
  end

  defp valuation_pair(board) do
    with %{"white" => white, "black" => black} <- Map.get(board, "postponed_as"),
         true <- white in ~w(win draw loss) and black in ~w(win draw loss) do
      Enum.sort([white, black])
    else
      _absent_or_unreadable -> :unknown
    end
  end

  @doc """
  The live rounds, in number order - see `live_round?/1`.
  """
  def live_rounds(payload), do: payload |> rounds() |> Enum.filter(&live_round?/1)

  @doc """
  Whether any round of the tournament is live. What the page refresher polls
  faster for.
  """
  def live?(payload), do: live_rounds(payload) != []

  @doc """
  Whether a tournament is over for good as far as the public pages are
  concerned: `status/1` says `:finished` and no round is still taking results.

  The refresher reads this (as `data-results-finished` in the page) to stop
  polling. A finished tournament does not change under a reader, and the
  event stream still wakes the page if the arbiter publishes a correction.
  """
  def settled?(payload), do: status(payload) == :finished and not live?(payload)

  @doc """
  A round's byes.
  """
  def byes(round), do: round |> list("byes") |> Enum.filter(&is_map/1)

  @doc """
  Every player in the payload.
  """
  def players(payload), do: payload |> list("players") |> Enum.filter(&is_map/1)

  @doc """
  The players indexed by `no`, the tournament pairing number.

  `no` is the only thing that identifies a player anywhere in the document -
  boards, byes and standings rows all reference it, and no database id ever
  crosses.
  """
  def players_by_no(payload) do
    Map.new(players(payload), &{Map.get(&1, "no"), &1})
  end

  @doc """
  One player, or `nil`.
  """
  def player(payload, no), do: Enum.find(players(payload), &(Map.get(&1, "no") == no))

  @doc """
  The `standings` object, or an empty one.
  """
  def standings(payload), do: object(payload, "standings")

  @doc """
  The standings rows, in the order the arbiter sent them.

  Never sorted here. `rank` is the arbiter's answer after their tiebreaks ran,
  and re-deriving the order from `points` would quietly disagree with it the
  moment two players are level.
  """
  def standings_rows(payload), do: standings(payload) |> list("rows") |> Enum.filter(&is_map/1)

  @doc """
  Which round the standings reflect, or `nil`.

  `0` reads as `nil` here, not as a round. OpenPairings writes
  `standings.after_round: 0` for a tournament nobody has closed a round of
  yet, and a page that printed it verbatim said "Standings after round 0" -
  a round that has never existed. Absent means the same thing for a payload
  from before this field existed, so the two collapse to one answer.
  """
  def after_round(payload) do
    case Map.get(standings(payload), "after_round") do
      round when is_integer(round) and round > 0 -> round
      _zero_or_absent -> nil
    end
  end

  @doc """
  Whether round `number` is one the STANDINGS-DERIVED pages - the
  cross-table and a player's card - may show a result for.

  Those two pages exist to agree with the standings table beside them, not
  to race ahead of it: an arbiter can publish round 6's boards while the
  standings still stop after round 5, and until they fold round 6 in, a page
  built to agree with the standings has nothing of its own to say about it.
  A round PAGE is not gated by this at all - `/round/:n` shows exactly what
  was published, live, the moment it arrives, because it never claimed to
  agree with anything but itself. See `TournamentController.round/2`.

  `false` for every round once `after_round/1` is `nil`: before the first
  standings are published there is nothing either page may show, which is
  the whole rule stated as a boundary of zero.

  This is the one place `crosstable/1` and `card/2` both read instead of
  each comparing to `after_round/1` on its own, so the boundary can only be
  wrong in one place.
  """
  @spec within_standings?(map(), integer()) :: boolean()
  def within_standings?(payload, number) when is_integer(number) do
    case after_round(payload) do
      nil -> false
      round -> number <= round
    end
  end

  @doc """
  Whether the standings page has nothing of its own to show yet: no rows, or
  no round to call them "after".

  This is the moment between a tournament being published and its first
  round closing: the arbiter's snapshot already carries every entered
  player, and there is nothing dishonest about showing them in starting
  order while the placings do not exist yet. `players(payload) != []` is
  what tells that state apart from a tournament with nothing published at
  all, which keeps its own "no standings" message - see
  `TournamentHTML.standings_table/1`.
  """
  def starting_rank?(payload) do
    (standings_rows(payload) == [] or is_nil(after_round(payload))) and players(payload) != []
  end

  @doc """
  Every player, in starting-number order - the field as entered, before a
  single result exists.

  What the standings page renders while `starting_rank?/1` holds. Not
  `crosstable/1`'s row shape: there is nothing yet to attach a cell to.
  """
  def starting_rank(payload) do
    payload
    |> players()
    |> Enum.filter(&(not is_nil(Map.get(&1, "no"))))
    |> Enum.sort_by(&Map.get(&1, "no"))
  end

  @doc """
  The label to print beside a board - what the hall's printed sheet says.

  Falls back to the raw board number, which is what every snapshot published
  before 2026-08-29 carries and what an ordinary board's label is anyway.

  The two differ when a fixed-table player is in the round: their board is
  renumbered (1001, say) and the boards after them close the gap. Rendering
  the raw column there put the public page and the printed sheet into
  disagreement about which game is board 12.
  """
  def board_label(board) do
    case Map.get(board, "label") do
      label when is_binary(label) and label != "" -> label
      _absent -> to_string(Map.get(board, "board"))
    end
  end

  @doc """
  Whether a hand-set order has stopped describing the tournament.

  `:stale` - a result changed since the arbiter last set the order.
  `:incomplete` - a player joined afterwards and has not been placed.

  Absent means no, for the same reason as everywhere else here: a payload
  that could not tell us has not made the claim, and inventing a warning on
  an arbiter's behalf is worse than omitting one. The arbiter's own standings
  page shows both, and until 2026-08-29 neither travelled - so this site said
  "the arbiter chose this order" while their screen said "...and it may no
  longer match the real standings".
  """
  def manual_warning?(payload, kind) when kind in [:stale, :incomplete] do
    key = if kind == :stale, do: "manual_stale", else: "manual_incomplete"

    manual_order?(payload) and Map.get(standings(payload), key) == true
  end

  @doc """
  Whether the arbiter set this order by hand rather than computing it.

  Absent means no, which is both the old behaviour and the honest one: a
  payload that does not mention hand-ordering is from an app that could not
  tell us, and claiming a disclosure the arbiter never made would be worse
  than omitting one.

  The rows are rendered in the sent order either way - see `standings_rows/1`.
  This exists so the page can SAY so. The arbiter's app used to carry that
  disclosure on its own public standings page; that page was removed on
  2026-08-29, and this is where it went.
  """
  def manual_order?(payload) do
    Map.get(standings(payload), "manual_order") == true
  end

  @doc """
  How to name a round, for a tournament played as matches.

  A round-robin or swiss played in two-game matches numbers its rounds 1..2n,
  but nobody in the hall calls round 4 "round 4" - it is game 2 of match 2,
  and that is what the arbiter's own round picker says. Absent means an
  ordinary tournament, which is almost all of them.
  """
  def match_format?(payload), do: Map.get(info(payload), "match_format") == true

  @doc "Short round label: `\"3\"`, or `\"M2-1\"` for a match-format event."
  def round_label(payload, number) when is_integer(number) do
    if match_format?(payload) do
      "M#{div(number - 1, 2) + 1}-#{if rem(number, 2) == 1, do: 1, else: 2}"
    else
      to_string(number)
    end
  end

  def round_label(_payload, number), do: to_string(number)

  @doc "Full round heading: `\"Round 3\"`, or `\"Match 2, game 1\"`."
  def round_heading(payload, number) when is_integer(number) do
    if match_format?(payload) do
      gettext("Match %{match}, game %{game}",
        match: div(number - 1, 2) + 1,
        game: if(rem(number, 2) == 1, do: 1, else: 2)
      )
    else
      gettext("Round %{number}", number: number)
    end
  end

  def round_heading(_payload, number), do: gettext("Round %{number}", number: number)

  @doc """
  The tournament facts a printed pairing sheet carries as a matter of course -
  deputy arbiter and time control, beside the chief arbiter the masthead
  already showed.

  Returns `[]` when the payload carries neither, which is every snapshot
  published before 2026-08-29 and most club events.
  """
  def officials(payload) do
    info = info(payload)

    [{"Deputy", string(info, "deputy")}, {"Tempo", string(info, "time_control")}]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  @doc """
  The declared tiebreaks, in the arbiter's chosen order.

  `rows[].tiebreaks` is positional against this list, which is what lets the
  renderer stay ignorant: it does not know what BH means, how many there are,
  or why this arbiter put Buchholz Cut-1 first.
  """
  def tiebreaks(payload), do: standings(payload) |> list("tiebreaks") |> Enum.filter(&is_map/1)

  @doc """
  A tiebreak's column heading: its label, or its code if the label is absent.
  """
  def tiebreak_label(tiebreak) do
    string(tiebreak, "label") || string(tiebreak, "code") || ""
  end

  @doc "A tiebreak's code as the document declares it, or nil."
  def tiebreak_code(tiebreak), do: string(tiebreak, "code")

  @doc """
  A tiebreak's short heading, for a column with no room for its name: the
  code the arbiter's app sends (the regulations' abbreviation), with the cut
  written the way the regulations write it - `BHC1` is `BH-C1`. The label
  when there is no code.
  """
  def tiebreak_short(tiebreak) do
    case string(tiebreak, "code") do
      nil -> tiebreak_label(tiebreak)
      code -> String.replace(code, ~r/^([A-Z]+?)([CM])(\d)$/, "\\1-\\2\\3")
    end
  end

  @doc """
  The tiebreak value in position `index` of a standings row.

  Positional, and short rows are tolerated rather than padded: a client that
  sent fewer values than it declared columns leaves a blank cell, which is
  honest, where a zero would be a value the arbiter never computed.
  """
  def tiebreak_value(row, index) do
    row |> list("tiebreaks") |> Enum.at(index)
  end

  @doc """
  Whether the placings above were decided partly by a tie-break the arbiter
  has not published.

  Hiding a column hides the arithmetic, not its effect: two players can sit
  one above the other with every published number identical and nothing on
  the page to say why. That reads as a broken table rather than a withheld
  one, so the document carries this and the page says so.

  Absent means no, which is what publishing meant before an arbiter could
  hide tie-breaks one at a time.
  """
  def tiebreaks_withheld?(payload), do: Map.get(standings(payload), "tiebreaks_withheld") == true

  @doc """
  Whether a standings row is a round-robin player whose results are not
  counted (FIDE C.05 6.6: withdrawn with fewer than half the games played).
  OpenPairings sends `"uncounted": true` on such a row and nothing
  otherwise. The row still carries a `rank` and `points`, for a server that
  has never heard of the key; this one shows neither as a place.
  """
  def uncounted?(row), do: is_map(row) and Map.get(row, "uncounted") == true

  @doc "The pairing numbers of the players whose results are not counted."
  def uncounted_players(payload) do
    for row <- standings_rows(payload), uncounted?(row), into: MapSet.new(), do: row["player"]
  end

  @doc """
  How many rows have a place - the "of 12" beside a rank. A row that is not
  counted is in the table and not in the ranking.
  """
  def ranked_total(payload), do: Enum.count(standings_rows(payload), &(not uncounted?(&1)))

  @doc """
  One player's standings row, or `nil`.
  """
  def standings_row(payload, no) do
    Enum.find(standings_rows(payload), &(Map.get(&1, "player") == no))
  end

  @doc """
  How each of `no`'s tiebreak numbers was arrived at, as
  `%{code => %{"total" => number, "parts" => [part]}}`.

  Empty when the arbiter has hidden the tiebreak columns - the working is
  withheld at build time in that case, so there is nothing here to hide - and
  empty for a tiebreak whose arithmetic is not a per-round sum, Direct
  Encounter being the one that matters.

  **Never computed here.** The contract's first rule is that the arbiter is
  the authority, and this is the sharpest case for it: Buchholz sums each
  opponent's Article 16 ADJUSTED score, not the score in their standings row,
  so adding up the numbers on this page would produce a total that disagrees
  with the one printed beside it. See `docs/snapshot-schema.md`.
  """
  def working(payload, no) do
    case standings_row(payload, no) do
      nil -> %{}
      row -> working_for_row(row)
    end
  end

  @doc """
  Same as `working/2`, for a standings ROW already in hand rather than a
  player number.

  `working/2` finds the row by searching `standings_rows/1`, which is fine
  once and quadratic across a whole table: the standings page itself walks
  every row to build the sortable, filterable table and, since this feature,
  a tiebreak cell's own expandable detail - see
  `OpenResultsWeb.TournamentHTML.standings_table/1` and `tiebreak_cell/1`.
  This is that walk's O(rows) instead of O(rows^2).
  """
  @spec working_for_row(map()) :: %{String.t() => %{String.t() => term()}}
  def working_for_row(row) when is_map(row) do
    row |> object("working") |> Map.new(fn {code, w} -> {code, normalise_working(w)} end)
  end

  defp normalise_working(working) when is_map(working) do
    %{
      "total" => Map.get(working, "total"),
      "parts" => working |> list("parts") |> Enum.filter(&is_map/1)
    }
  end

  defp normalise_working(_not_a_map), do: %{"total" => nil, "parts" => []}

  @doc """
  A part's kind: `"played"`, `"virtual"`, `"cut"` or `"excluded"`.

  Absent means `"played"`, which is the commonest by a wide margin and so is
  not sent - the same absent-means-the-default reading `listed` and
  `manual_order` already have.
  """
  def part_kind(part), do: string(part, "kind") || "played"

  @doc """
  Whether a part was counted towards its tiebreak's total.

  `"cut"` and `"excluded"` parts are published precisely so a reader can see
  what did NOT count and why; they must never be added back in.
  """
  def part_counted?(part), do: part_kind(part) in ["played", "virtual"]

  @doc """
  The tiebreaks with published working, in the arbiter's own column order.

  Ordered by `standings.tiebreaks` rather than by the working map's keys, so
  the explanation on a player's page reads down in the same order as the
  columns on the standings table.
  """
  def working_codes(payload, no) do
    working = working(payload, no)

    payload
    |> tiebreaks()
    |> Enum.map(&string(&1, "code"))
    |> Enum.filter(&Map.has_key?(working, &1))
  end

  @doc """
  Points the result token awards, as `{white, black}`, or `nil`.

  A token this server has never seen returns `nil` rather than a guess.
  """
  def result_points(token), do: Map.get(@result_points, token)

  @doc """
  What each seat of a board scored, as `{white, black}`, or `nil` when that
  cannot be known.

  Read from `boards[].points`: the figures OpenPairings scored the game with,
  under the tournament's own point system, presence points included, and for
  a postponed game what it is credited with while it waits. The result token
  is never interpreted when those are present.

  A snapshot from before `boards[].points` existed has none, and then the
  token is read as 1 / half / 0 (`result_points/1`) - the only reading
  available to it - while a postponed board is `nil`, since how it is valued
  is not in such a snapshot.
  """
  def board_points(board) when is_map(board) do
    case Map.get(board, "points") do
      %{"white" => white, "black" => black} when is_number(white) and is_number(black) ->
        {white, black}

      _absent_or_unreadable ->
        if outstanding?(board), do: nil, else: result_points(Map.get(board, "result"))
    end
  end

  def board_points(_not_a_board), do: nil

  @doc """
  Whether this snapshot comes from a publisher that sends the point system
  and per-game points - `tournament.scoring`. Absent means an older one.
  """
  def scoring_published?(payload), do: is_map(Map.get(info(payload), "scoring"))

  @doc """
  A result token split into what to show and what it needs explaining as:
  `{base, note}`.

  The token is what travels and the renderer may present it however it likes.
  A spectator needs to see that a 1-0 was never played, and that another one
  will not move a rating, so the FIDE Art. 16 forfeit and the unrated marker
  are lifted out of the token and shown as words.

  A token from a newer client comes back verbatim and unannotated. Guessing at
  a suffix nobody here has been taught would be inventing a meaning.
  """
  def result_parts(token) when is_binary(token) do
    cond do
      not Map.has_key?(@result_points, token) -> {token, nil}
      String.ends_with?(token, "FF") -> {String.replace_suffix(token, "FF", ""), "forfeit"}
      String.ends_with?(token, "U") -> {String.replace_suffix(token, "U", ""), "unrated"}
      true -> {token, nil}
    end
  end

  # A result that is not a token is not a result. Rendered as an unreported
  # game rather than raising, because a malformed payload should cost the page
  # one cell, not the whole tournament.
  def result_parts(_absent_or_not_a_token), do: {nil, nil}

  @doc """
  One player's tournament, round by round - up to the round the published
  standings reflect, and no further.

  Carries an entry for every round IN THAT RANGE, published or not, because
  a card with round 4 silently missing reads as a player who sat out rather
  than as an arbiter who has not published yet. A round beyond the range -
  published, live, with real boards and a real result - gets no entry at
  all: this is a standings-derived page, and showing its game before the
  arbiter has folded that round into the standings shown beside it is
  exactly the leak `within_standings?/2` exists to close. Empty before the
  first standings are published.

  `:score` is the running total, and it is the only number on this site that
  did not arrive ready-made - the contract carries no per-game points on
  purpose. It stops, `nil` from there on, the moment a round's contribution is
  unknowable: an unpublished round, a board the arbiter hid, a game with no
  result yet, or a token this server cannot read. A total that stepped over a
  gap would be a number the arbiter never agreed to, and the standings page
  is where the authoritative one lives.
  """
  def card(payload, no) do
    index = players_by_no(payload)
    # Built once. `card_entry/5` used to call `round/2` per slot, and that
    # re-sorts the whole round list each time - so a card cost O(slots x
    # rounds) where the payload alone decides both.
    by_number = rounds_by_number(payload)
    uncounted = uncounted_players(payload)

    payload
    |> round_slots()
    |> Enum.filter(&within_standings?(payload, &1))
    # The card stops at a round whose results are withheld: the page says so
    # once, rather than a row of nothing, and a running score never steps
    # over the gap. OpenPairings never puts such a round inside the
    # standings, so this is the guard for a document that does.
    |> Enum.take_while(&results_public?(Map.get(by_number, &1)))
    |> Enum.map_reduce({:known, 0.0}, fn number, running ->
      entry = card_entry(index, by_number, number, no)

      # A game against a player whose results are not counted (C.05 6.6)
      # stays on the card and adds nothing: the standings, which this total
      # has to land on, left it out. The withdrawn player's own card adds
      # up as played - it is the record of what they did.
      set_aside? =
        entry.kind == :game and MapSet.member?(uncounted, entry.opponent_no) and
          not MapSet.member?(uncounted, no)

      running =
        if set_aside?,
          do: running,
          else: advance(running, entry.points || entry.provisional_points)

      {entry |> Map.put(:score, running_score(running)) |> Map.put(:uncounted?, set_aside?),
       running}
    end)
    |> elem(0)
  end

  defp card_entry(index, by_number, number, no) do
    entry = %{
      round: number,
      date: nil,
      kind: :unpublished,
      colour: nil,
      board: nil,
      opponent: nil,
      opponent_no: nil,
      result: nil,
      postponed: false,
      pending: false,
      postponed_date: nil,
      bye: nil,
      points: nil,
      provisional_points: nil
    }

    case Map.get(by_number, number) do
      nil ->
        entry

      round ->
        entry = %{entry | date: string(round, "date")}

        cond do
          board = find_board(round, no) -> game_entry(entry, board, index, no)
          bye = find_bye(round, no) -> bye_entry(entry, bye)
          # The round is published but this player is not in it. Either they
          # were left unpaired or their board was withheld, and the payload
          # cannot tell the two apart - by design, since a hidden board is
          # absent rather than flagged. So the page says only what is true.
          true -> %{entry | kind: :no_game}
        end
    end
  end

  defp game_entry(entry, board, index, no) do
    colour = if Map.get(board, "white") == no, do: :white, else: :black
    opponent_no = if colour == :white, do: Map.get(board, "black"), else: Map.get(board, "white")
    result = Map.get(board, "result")

    mine =
      case board_points(board) do
        {white, black} -> if colour == :white, do: white, else: black
        nil -> nil
      end

    # A postponed game has no result to score yet. What it is credited with
    # while it waits travels apart from `points`, so the row still shows no
    # score for it and the running total still counts it, as OpenPairings'
    # own does.
    #
    # A pending board (`pending?/1`) is read the same way; `pending` only
    # changes what the row says about it.
    postponed = outstanding?(board)
    points = if postponed, do: nil, else: mine

    %{
      entry
      | kind: :game,
        colour: colour,
        board: Map.get(board, "board"),
        opponent: Map.get(index, opponent_no),
        opponent_no: opponent_no,
        result: result,
        postponed: postponed,
        pending: pending?(board),
        postponed_date: postponed_date(board),
        points: points,
        provisional_points: if(postponed, do: mine)
    }
  end

  defp bye_entry(entry, bye) do
    points = Map.get(bye, "points")

    %{
      entry
      | kind: :bye,
        bye: string(bye, "kind"),
        points: if(is_number(points), do: points)
    }
  end

  # What a cell holds before anything is known about it. One shape for all
  # four kinds, so the template reads `cell.points` without asking first -
  # the same trick `card_entry/4` plays a few lines up.
  # The opponent is named by NUMBER and nothing else, which is the one place
  # this differs from `card/2`'s entries. A grid cell has room for a pairing
  # number and not for "Ó Súilleabháin, Séamus", and the number is what the
  # row a reader then goes looking for is keyed by.
  @empty_cell %{
    round: nil,
    kind: :none,
    colour: nil,
    opponent_no: nil,
    result: nil,
    bye: nil,
    points: nil,
    postponed: false,
    pending: false,
    postponed_date: nil
  }

  @doc """
  The whole tournament as one grid: a row per player, a column per PUBLISHED
  round, and in each cell the game that player had that round, read from
  their own side.

  Each row is `%{no:, player:, rank:, points:, cells: [cell]}`, and `cells`
  is positional against `round_numbers/1` - the same discipline
  `rows[].tiebreaks` uses against `standings.tiebreaks`, and for the same
  reason: the caller renders columns without knowing what a round is.

  ## Why the columns are rounds

  The other cross-table is the all-play-all square, one column per player,
  and for a round-robin of twelve it is the better document. It is not the
  one to build here. It has no cell for a bye, a forfeit against an empty
  seat or a round somebody sat out - all three simply vanish, and the row
  stops adding up to the score printed beside it. And it is quadratic: a
  450-player open is 202,500 cells, which is not a page. Rounds are what
  every result actually belongs to, and one column per round reads the same
  for a swiss, a round-robin and a keizer ladder.

  ## Why the rows are in starting-number order

  Not the standings' order, though that order is right there and this app
  renders it faithfully everywhere else. Every cell names its opponent by
  `no` and nothing else, so a reader who has just read `6w1` wants row 6 -
  and finds it, by counting, instead of hunting through a ranking. It also
  means the grid says something the standings page does not, and that it
  renders identically for a tournament whose arbiter publishes no standings
  at all.

  `rank`, `points` and `score` are the arbiter's own, lifted from the
  standings row when there is one and `nil` when there is not - a player
  entered and not yet placed, which is every player before round one.

  All three travel because a Keizer ladder's `points` are not the sum of the
  row beside them: they are the ladder's own currency, and `score` is the
  game score. Which of the two belongs at the end of a row of results is a
  question about presentation, so it is answered where the columns are
  chosen rather than here.

  ## The standings gate

  "Published" above means published AND no later than `after_round/1` - see
  `within_standings?/2`. A round can be live, with boards and results, before
  the arbiter has folded it into the standings beside this grid, and until
  they do this page has nothing of its own to say about it either: it exists
  to agree with the standings, not to race ahead of them. A round's own page
  is unaffected and keeps showing it the moment it is published. Empty
  before the first standings are published.
  """
  def crosstable(payload) do
    numbers = crosstable_rounds(payload)
    placings = Map.new(standings_rows(payload), &{Map.get(&1, "player"), &1})

    # One pass over every board and bye in the tournament, and then a lookup
    # per cell. `card/2` searches each round's boards for one player, which
    # is right for one card and quadratic for a page of them: a round's
    # boards are half its players, so the obvious loop costs players x rounds
    # x players/2 - about 1.1 million comparisons on a 450-player, 11-round
    # event, per render.
    #
    # Built from the GATED rounds only, not every published one, so a round
    # beyond `after_round/1` cannot end up in `cells` at all - not merely
    # unreachable through `numbers` below, but never read off `rounds(payload)`
    # in the first place.
    cells =
      payload
      |> rounds()
      |> Enum.filter(&(within_standings?(payload, number_of(&1)) and results_public?(&1)))
      |> Map.new(&{number_of(&1), round_cells(&1)})

    for player <- Enum.sort_by(players(payload), &Map.get(&1, "no")),
        no = Map.get(player, "no"),
        not is_nil(no) do
      placing = Map.get(placings, no, %{})

      %{
        no: no,
        player: player,
        # `placing` is `%{}` for a player the standings do not carry, and
        # `Map.get/2` on it is `nil` three times over - which is what the
        # renderer prints as an empty cell rather than as a zero.
        rank: if(uncounted?(placing), do: nil, else: Map.get(placing, "rank")),
        points: Map.get(placing, "points"),
        score: Map.get(placing, "score"),
        # C.05 6.6: the row is the record of the games, not a placing.
        uncounted?: uncounted?(placing),
        cells: Enum.map(numbers, &cell_for(cells, &1, no))
      }
    end
  end

  @doc """
  The cross-table's columns: the published rounds no later than the standings
  (`within_standings?/2`), without a round whose results are withheld - the
  page says that once rather than showing a column of nothing. The one list
  both `crosstable/1`'s cells and the page's column headings are built from.
  """
  def crosstable_rounds(payload) do
    withheld = withheld_result_rounds(payload)

    payload
    |> round_numbers()
    |> Enum.filter(&within_standings?(payload, &1))
    |> Enum.reject(&(&1 in withheld))
  end

  defp cell_for(cells, number, no) do
    cells |> Map.get(number, %{}) |> Map.get(no, %{@empty_cell | round: number})
  end

  # Every seat in one round, keyed by the player sitting in it.
  #
  # Byes first and boards over them, so a player who is somehow in both is
  # shown their game - which is what `card_entry/4` decides too. The two
  # pages must not disagree about the same round.
  defp round_cells(round) do
    number = number_of(round)

    from_byes =
      for bye <- byes(round),
          no = Map.get(bye, "player"),
          not is_nil(no),
          into: %{},
          do: {no, bye_cell(bye, number)}

    for board <- boards(round),
        {no, cell} <- board_cells(board, number),
        not is_nil(no),
        into: from_byes,
        do: {no, cell}
  end

  # The two halves of one board, each handed to the seat it belongs to.
  #
  # This is the line a cross-table gets wrong. `1-0` is a win for the seat on
  # the left of the token and a LOSS for the seat on the right, so a cell
  # showing the board's token in both players' rows tells the loser they won,
  # and it is invisible unless somebody checks both halves. The token is
  # split once, here, by the same `result_points/1` the player card and the
  # running scores already use - so the three cannot drift into different
  # answers about one game.
  defp board_cells(board, number) do
    white = Map.get(board, "white")
    black = Map.get(board, "black")
    result = Map.get(board, "result")
    postponed = outstanding?(board)
    pending = pending?(board)
    postponed_date = postponed_date(board)

    # A token this server cannot read leaves BOTH seats without a score
    # rather than one of them with a guess. The renderer shows the token as
    # it arrived and says nothing about who won.
    {white_points, black_points} =
      if postponed, do: {nil, nil}, else: board_points(board) || {nil, nil}

    [
      {white,
       game_cell(
         number,
         :white,
         black,
         result,
         white_points,
         {postponed, pending},
         postponed_date
       )},
      {black,
       game_cell(
         number,
         :black,
         white,
         result,
         black_points,
         {postponed, pending},
         postponed_date
       )}
    ]
  end

  defp game_cell(
         number,
         colour,
         opponent_no,
         result,
         points,
         {postponed, pending},
         postponed_date
       ) do
    %{
      @empty_cell
      | round: number,
        kind: :game,
        colour: colour,
        opponent_no: opponent_no,
        result: result,
        points: points,
        # Same flag and date as `card_entry/4`'s own cell, ungated here too -
        # the view gates the date on `display.dates`, exactly as it does for
        # a round and a player's card, so this is not a second answer to the
        # same question.
        postponed: postponed,
        pending: pending,
        postponed_date: postponed_date
    }
  end

  defp bye_cell(bye, number) do
    points = Map.get(bye, "points")

    %{
      @empty_cell
      | round: number,
        kind: :bye,
        bye: string(bye, "kind"),
        points: if(is_number(points), do: points)
    }
  end

  @doc """
  Each player's total as the arbiter computed it, as `%{no => points}`.

  From `standings.rows`, not derived. This is the authoritative number - the
  one the arbiter's tiebreaks ran against - and re-deriving it here would
  produce a second answer that quietly disagrees the moment a game is
  adjudicated or a forfeit is entered after the fact.

  Missing for a player with no standings row, which reads as "unknown" rather
  than zero.
  """
  def standings_points(payload) do
    for row <- standings_rows(payload),
        no = Map.get(row, "player"),
        not is_nil(no),
        into: %{},
        do: {no, Map.get(row, "points")}
  end

  @doc """
  Every player's score going INTO round `number`, as `%{no => points}`.

  What a pairing list means by "score": the points each player carried into
  the round, which is what explains why these two are on this board. The
  points they end the round with are on the standings.

  `nil` for a player whose total cannot be known, under exactly the rule
  `card/2` uses - an unpublished earlier round, a board the arbiter withheld,
  a game with no result yet, or a token this server cannot read. The two must
  agree: a player card and a pairing list disagreeing about the same number
  would be this site contradicting itself.

  **Points are read, never worked out.** A board carries what each seat
  scored (`boards[].points`, see `board_points/1`) under the tournament's own
  point system, and a postponed board carries what it is credited with while
  it waits - a draw by default, a win or a loss when the rules say so. So the
  total here is the sum OpenPairings' own pairing list shows, a postponed game
  included, under any point system.

  **Older snapshots** (no `tournament.scoring`) carry no per-game points, so
  two fallbacks keep them from being wrong rather than merely incomplete:

  * **The standings are the anchor.** When `standings.after_round` is below
    `number`, each player the standings list starts from `standings.rows[].points`
    - OpenPairings' own total after that round - and only the rounds after it
    are added up, with a played game read as 1/half/0 from its token.
  * **A postponed board is unknown.** Its valuation is not in such a
    snapshot, so a postponed board in a round the standings do not cover
    leaves both seats `nil` (see `score_gaps/2` for the reason).

  One pass over the earlier rounds rather than `card/2` per player, which
  would re-walk every round's boards once per seat on the page.
  """
  def scores_before(payload, number) do
    payload
    |> score_states(number)
    |> Map.new(fn {no, state} -> {no, running_score(state)} end)
  end

  @doc """
  Why a player's score into round `number` is unknown, for the players whose
  it is: `%{no => :postponed | :gap}`. `:postponed` when the first thing that
  stopped the total was a postponed game whose points the snapshot does not
  carry, `:gap` for everything else (an unpublished or withheld round, a game
  with no result). A player with a known score is not in the map.
  """
  def score_gaps(payload, number) do
    for {no, {:unknown, reason}} <- score_states(payload, number), into: %{}, do: {no, reason}
  end

  defp score_states(payload, number) do
    earlier = payload |> round_slots() |> Enum.filter(&(&1 < number))
    by_number = rounds_by_number(payload)

    uncounted = uncounted_players(payload)

    contributions =
      Map.new(earlier, fn n ->
        round = Map.get(by_number, n)
        {n, round |> round_contributions() |> set_aside(round, uncounted)}
      end)

    {anchor_round, anchors} = standings_anchor(payload, number)

    for player <- players(payload), no = Map.get(player, "no"), into: %{} do
      # A player the standings cover starts from the total OpenPairings
      # published for them after `anchor_round`, so the rounds already inside
      # it are not added up here at all.
      {from, start} =
        case Map.fetch(anchors, no) do
          {:ok, points} -> {anchor_round, {:known, points}}
          :error -> {0, {:known, 0.0}}
        end

      total =
        Enum.reduce(earlier, start, fn n, state ->
          if n > from,
            do: advance_score(state, Map.get(contributions[n], no, :absent)),
            else: state
        end)

      {no, total}
    end
  end

  # The one total in the document, for a snapshot without per-game points,
  # that OpenPairings computed with the tournament's own point system and its
  # own value for a postponed game: `standings.rows[].points` after
  # `standings.after_round`. Returned as `{round, %{no => points}}` when the
  # standings stop before round `number`, and `{0, %{}}` when they do not (so
  # there is nothing to start from) or when the snapshot carries per-game
  # points, which are exact for every round and need no anchor.
  #
  # A Keizer table ranks on Keizer points, so its game score is `score`.
  defp standings_anchor(payload, number) do
    case if(scoring_published?(payload), do: nil, else: after_round(payload)) do
      round when is_integer(round) and round < number ->
        # OpenPairings never puts a withheld round inside its standings; a
        # document that does is not one to anchor a running score on.
        if Enum.any?(withheld_result_rounds(payload), &(&1 <= round)),
          do: {0, %{}},
          else: anchors_after(payload, round)

      _standings_not_before_this_round ->
        {0, %{}}
    end
  end

  defp anchors_after(payload, round) do
    key = if info(payload)["system"] == "keizer", do: "score", else: "points"

    anchors =
      for row <- standings_rows(payload),
          no = Map.get(row, "player"),
          not is_nil(no),
          is_number(Map.get(row, key)),
          into: %{},
          do: {no, Map.get(row, key) * 1.0}

    {round, anchors}
  end

  # `%{no => points}` for one round, or an empty map for a round that was
  # never published - which leaves every player `:absent`, i.e. unknown,
  # which is the honest answer for a round nobody can see.
  defp round_contributions(nil), do: %{}

  # A round whose results are withheld contributes nothing known to anyone -
  # not even a bye's points, which do travel: a running score that moved for
  # the players with a bye and stopped for everyone else would be a partial
  # result of a round the arbiter has not published.
  defp round_contributions(%{"results_public" => false}), do: %{}

  defp round_contributions(round) do
    from_boards =
      for board <- boards(round),
          {seat, points} <- board_contributions(board),
          not is_nil(seat),
          into: %{},
          do: {seat, points}

    for bye <- byes(round),
        no = Map.get(bye, "player"),
        not is_nil(no),
        into: from_boards,
        do: {no, Map.get(bye, "points")}
  end

  # The games against a player whose results are not counted (C.05 6.6) add
  # nothing to the other seat, as in the standings. Nothing to do in every
  # event that has no such player, which is nearly all of them.
  defp set_aside(contributions, round, uncounted) do
    if MapSet.size(uncounted) == 0 or contributions == %{} do
      contributions
    else
      for board <- boards(round),
          {seat, other} <- [
            {Map.get(board, "white"), Map.get(board, "black")},
            {Map.get(board, "black"), Map.get(board, "white")}
          ],
          MapSet.member?(uncounted, other) and not MapSet.member?(uncounted, seat),
          is_number(Map.get(contributions, seat)),
          reduce: contributions do
        acc -> Map.put(acc, seat, 0.0)
      end
    end
  end

  defp board_contributions(board) do
    seats = [Map.get(board, "white"), Map.get(board, "black")]

    case board_points(board) do
      {white, black} ->
        Enum.zip(seats, [white, black])

      # No points: a board with no result yet contributes an unknown to BOTH
      # seats, rather than nothing - a game in progress is not a game worth
      # zero. A postponed game with no published points is an older snapshot
      # that does not say how it is valued - see `scores_before/2`.
      nil ->
        gap = if outstanding?(board), do: :postponed, else: :unknown
        Enum.map(seats, &{&1, gap})
    end
  end

  defp find_board(round, no) do
    Enum.find(boards(round), &(Map.get(&1, "white") == no or Map.get(&1, "black") == no))
  end

  defp find_bye(round, no), do: Enum.find(byes(round), &(Map.get(&1, "player") == no))

  defp advance({:known, total}, points) when is_number(points), do: {:known, total + points}
  defp advance(_gap_reached_or_reaching, _points), do: :unknown

  # `advance/2` that remembers why it stopped, for `score_gaps/2`.
  defp advance_score({:known, total}, points) when is_number(points), do: {:known, total + points}
  defp advance_score({:known, _total}, :postponed), do: {:unknown, :postponed}
  defp advance_score({:known, _total}, _gap), do: {:unknown, :gap}
  defp advance_score({:unknown, _reason} = stopped, _points), do: stopped

  defp running_score({:known, total}), do: total
  defp running_score(_unknown), do: nil

  ## ---------- team tournaments ----------

  @doc """
  Whether this is a team event - `tournament.team_event`. Absent means an
  individual tournament, exactly like every other flag here.
  """
  def team_event?(payload), do: Map.get(info(payload), "team_event") == true

  @doc "Every team in the payload."
  def teams(payload), do: payload |> list("teams") |> Enum.filter(&is_map/1)

  @doc "The teams indexed by `no`, the team's own pairing number."
  def teams_by_no(payload), do: Map.new(teams(payload), &{Map.get(&1, "no"), &1})

  @doc "One team, or `nil`."
  def team(payload, no), do: Enum.find(teams(payload), &(Map.get(&1, "no") == no))

  @doc """
  The label to print for a team: its full name, everywhere a team is shown
  (team pages, matches, standings, cross-tables, the hall display and the
  projector view). The short name is only the fallback for a payload whose
  team carries no `name` - it used to win, and the hall screen then showed
  "Eupen" where the club is "Koninklijke Schaakkring Eupen".
  """
  def team_label(%{} = team) do
    string(team, "name") || string(team, "short_name") || ""
  end

  def team_label(_not_a_team), do: ""

  @doc """
  A team's roster, in board order, as player objects - `teams[].players`
  (a list of `no`) resolved against `players_by_no/1`. A `no` the payload
  cannot resolve is left out rather than rendered as a blank row.
  """
  def team_roster(payload, %{} = team) do
    index = players_by_no(payload)

    team
    |> Map.get("players", [])
    |> List.wrap()
    |> Enum.map(&Map.get(index, &1))
    |> Enum.reject(&is_nil/1)
  end

  def team_roster(_payload, _not_a_team), do: []

  @doc """
  The team `no` plays for, or `nil` - built from every team's roster, for the
  filter bar's "Team" control on board lines.
  """
  def player_team_no(payload, no) when not is_nil(no) do
    Enum.find_value(teams(payload), fn team ->
      if no in Map.get(team, "players", []), do: Map.get(team, "no")
    end)
  end

  def player_team_no(_payload, _no), do: nil

  @doc "A round's matches - `rounds[].matches`, present only for a team event."
  def matches(round), do: round |> list("matches") |> Enum.filter(&is_map/1)

  @doc """
  Every match `team_no` played, across every published round, oldest first -
  `%{round:, match:}`. What a team's page lists as its match history.
  """
  def team_matches(payload, team_no) do
    for round <- rounds(payload),
        match <- matches(round),
        Map.get(match, "team_a") == team_no or Map.get(match, "team_b") == team_no,
        do: %{round: number_of(round), match: match}
  end

  @doc "Which side of `match` is `team_no` - `:a`, `:b`, or `nil`."
  def match_side(match, team_no) do
    cond do
      Map.get(match, "team_a") == team_no -> :a
      Map.get(match, "team_b") == team_no -> :b
      true -> nil
    end
  end

  @doc "`team_no`'s opponent in `match`, or `nil` for a bye or an unrelated match."
  def match_opponent(match, team_no) do
    case match_side(match, team_no) do
      :a -> Map.get(match, "team_b")
      :b -> Map.get(match, "team_a")
      nil -> nil
    end
  end

  @doc """
  `team_no`'s own game points and match points in `match`, as `{gp, mp}` -
  either half `nil` while withheld or not yet decided (see
  `matches[].game_points`/`match_points` in `docs/snapshot-schema.md`).
  `{nil, nil}` for a bye or a match this team is not in.
  """
  def match_points_for(match, team_no) do
    case match_side(match, team_no) do
      :a -> {get_in(match, ["game_points", "a"]), get_in(match, ["match_points", "a"])}
      :b -> {get_in(match, ["game_points", "b"]), get_in(match, ["match_points", "b"])}
      nil -> {nil, nil}
    end
  end

  @doc """
  The team number the arbiter awarded `match` to by decision
  (`matches[].forfeit_decision`), or `nil` - for a match decided on its
  boards, for a decision withheld with the match points, and for a payload
  from a publisher older than the field. Read, never worked out: a match
  whose boards all show forfeits is not taken to be a decision.
  """
  def forfeit_decision_to(match) do
    case Map.get(match, "forfeit_decision") do
      %{"to" => no} when is_integer(no) -> no
      _ -> nil
    end
  end

  @doc "Which team has White on board 1 of `match` (see `matches[].board1_white_team`)."
  def match_white_team(match), do: Map.get(match, "board1_white_team")

  @doc "The `team_standings` object, or an empty one."
  def team_standings(payload), do: object(payload, "team_standings")

  @doc "Team standings rows, in the arbiter's own order - never re-sorted here."
  def team_standings_rows(payload),
    do: team_standings(payload) |> list("rows") |> Enum.filter(&is_map/1)

  @doc "One team's standings row, or `nil`."
  def team_standings_row(payload, no) do
    Enum.find(team_standings_rows(payload), &(Map.get(&1, "team") == no))
  end

  @doc "Which round the team standings reflect - same reading as `after_round/1`."
  def team_after_round(payload) do
    case Map.get(team_standings(payload), "after_round") do
      round when is_integer(round) and round > 0 -> round
      _zero_or_absent -> nil
    end
  end

  @doc "The declared team tie-breaks, in the arbiter's chosen order."
  def team_tiebreaks(payload),
    do: team_standings(payload) |> list("tiebreaks") |> Enum.filter(&is_map/1)

  @doc "Same as `working/2`, for `team_standings.rows[].working`."
  def team_working(payload, no) do
    case team_standings_row(payload, no) do
      nil -> %{}
      row -> working_for_row(row)
    end
  end

  @doc """
  Whether a team page has anything of its own to show yet - same reading as
  `starting_rank?/1`: no rows, or no round to call them "after".
  """
  def team_standings_pending?(payload) do
    team_standings_rows(payload) == [] or is_nil(team_after_round(payload))
  end

  @doc "Every board-prize row - `board_stats[]`, present only for a team event."
  def board_stats(payload), do: payload |> list("board_stats") |> Enum.filter(&is_map/1)

  @doc """
  `board_stats/1`, grouped by board number and sorted by it - what the board
  prizes page renders one table per.
  """
  def board_stats_by_board(payload) do
    board_stats(payload)
    |> Enum.group_by(&Map.get(&1, "board"))
    |> Enum.sort_by(fn {board, _rows} -> board end)
  end

  @doc """
  Whether the tournament offers the team-vs-team GRID: a team event played
  as a round robin, where every pair of teams meets and a cell per pair
  says how. A team Swiss does not fill a grid - most pairs never meet - and
  gets the round-by-round table instead (`team_round_crosstable?/1`).
  """
  def team_crosstable?(payload), do: team_event?(payload) and system(payload) == "roundrobin"

  @doc """
  Whether this is a team event paired as a Swiss - team against team, by
  C.04.6, since OpenPairings 0.62.0.
  """
  def team_swiss?(payload), do: team_event?(payload) and system(payload) == "swiss"

  @doc """
  Whether the tournament offers the team cross-table by round: a team event
  that is not a round robin and has at least one scheduled match to put in
  it. A team event that has not paired a round yet has nothing to grid.
  """
  def team_round_crosstable?(payload) do
    team_event?(payload) and system(payload) != "roundrobin" and
      Enum.any?(rounds(payload), &(matches(&1) != []))
  end

  @doc """
  The team-vs-team grid for a team round robin: a row per team, a column per
  OTHER team, and in each cell the match (or matches - a double round robin
  meets twice) between them.

  Each row is `%{no:, team:, rank:, mp:, gp:, cells: %{opponent_no => [match]}}`.
  `cells` is a map rather than a positional list, unlike `crosstable/1`'s -
  there is no fixed round to be positional against here, and a double round
  robin's reversed second meeting is a second entry in the same cell rather
  than a second column.
  """
  def team_crosstable(payload) do
    placings = Map.new(team_standings_rows(payload), &{Map.get(&1, "team"), &1})

    all_matches =
      for round <- rounds(payload),
          match <- matches(round),
          do: %{round: number_of(round), match: match}

    for team <- Enum.sort_by(teams(payload), &Map.get(&1, "no")),
        no = Map.get(team, "no"),
        not is_nil(no) do
      placing = Map.get(placings, no, %{})

      cells =
        all_matches
        |> Enum.filter(&(match_opponent(&1.match, no) != nil))
        |> Enum.group_by(&match_opponent(&1.match, no))

      %{
        no: no,
        team: team,
        rank: Map.get(placing, "rank"),
        mp: Map.get(placing, "mp"),
        gp: Map.get(placing, "gp"),
        cells: cells
      }
    end
  end

  ## ---------- boards inside matches ----------

  @doc """
  A round's published boards, indexed by their real round-wide number
  (`boards[].board`) - what `match_slots/2` looks boards up in.
  """
  def board_index(round) do
    round |> boards() |> Map.new(&{Map.get(&1, "board"), &1})
  end

  @doc """
  The boards of one match, in board order, each as `%{k:, number:, board:}`.

  `k` is the board's place inside the match - board 1, 2, 3 of that match,
  which is what a captain and a team sheet call it. The snapshot carries the
  round-wide `number` only (`matches[].boards`), so `k` is the position in
  that sorted list: OpenPairings numbers a match's boards consecutively
  (`(match - 1) * boards + k`) and lists every one of them, a seat nobody
  filled included. A board the arbiter hid is left out of the list and would
  shift the ones after it - an arbiter's display choice, and the only case
  this reading is off.

  `board` is the published board, or `nil` for a number listed in the match
  that has no game on the page: a seat one team could not fill (the other
  side's board is a forfeit win, counted in the match's game points, with no
  opponent to name).

  Takes a round, or the `board_index/1` of one when several matches of the
  same round are read.
  """
  def match_slots(round_or_index, match) do
    index =
      if Map.has_key?(round_or_index, "number"),
        do: board_index(round_or_index),
        else: round_or_index

    match
    |> board_positions()
    |> Enum.map(fn {number, k} -> %{k: k, number: number, board: Map.get(index, number)} end)
  end

  # `[{board number, k}]` for a match: OpenPairings' own
  # `matches[].board_positions` when the payload has it (since 2026-10-03),
  # so a hidden board shifts nothing; otherwise, for an older payload, the
  # position in the sorted `boards` list, which is exact unless a board was
  # hidden.
  defp board_positions(match) do
    case Map.get(match, "board_positions") do
      positions when is_list(positions) and positions != [] ->
        for %{"board" => number, "k" => k} <- positions,
            is_integer(number) and is_integer(k),
            do: {number, k}

      _absent ->
        match
        |> Map.get("boards", [])
        |> List.wrap()
        |> Enum.filter(&is_integer/1)
        |> Enum.sort()
        |> Enum.with_index(1)
    end
  end

  @doc """
  Whether `match` is a double forfeit - neither team turned up, both lost by
  forfeit (`matches[].double_forfeit`, sent with the match points). Read,
  never worked out from the boards.
  """
  def double_forfeit?(match), do: Map.get(match, "double_forfeit") == true

  @doc """
  Boards per match (`tournament.team_boards`), or `nil` for a payload from a
  publisher older than the field.
  """
  def team_boards(payload) do
    case get_in(payload, ["tournament", "team_boards"]) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc """
  Which match, and which board of it, each board of `round` belongs to:
  `%{board_number => %{match:, k:}}`. Empty for an individual round. What the
  pairing list uses to group a team round's boards under their matches.
  """
  def board_matches(round) do
    index = board_index(round)

    for match <- matches(round),
        Map.get(match, "bye") != true,
        slot <- match_slots(index, match),
        slot.board != nil,
        into: %{},
        do: {slot.number, %{match: match, k: slot.k}}
  end

  ## ---------- team pages ----------

  @doc """
  The teams for the team list, best placed first: `%{no:, team:, rank:, mp:,
  gp:, rating:, roster:}` with `roster` the team's players in board order and
  `rating` the team's rating as OpenPairings worked it out
  (`teams[].rating`, since 2026-10-03), `nil` when it sent none. In team
  number order until the team standings carry a rank. Read, never ranked
  here.
  """
  def team_list(payload) do
    placings = Map.new(team_standings_rows(payload), &{Map.get(&1, "team"), &1})

    payload
    |> teams()
    |> Enum.filter(&is_integer(Map.get(&1, "no")))
    |> Enum.map(fn team ->
      no = Map.get(team, "no")
      placing = Map.get(placings, no, %{})

      %{
        no: no,
        team: team,
        rank: Map.get(placing, "rank"),
        mp: Map.get(placing, "mp"),
        gp: Map.get(placing, "gp"),
        rating: team_rating(team),
        roster: team_roster(payload, team)
      }
    end)
    |> Enum.sort_by(&{&1.rank || 1_000_000, &1.no})
  end

  # A whole positive number, or nil - an older payload has no key, and a team
  # OpenPairings could not rate (no players, nothing typed in) sends null.
  defp team_rating(team) do
    case Map.get(team, "rating") do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc """
  One team's line-up in every round it was scheduled, oldest first:
  `%{round:, match:, bye?:, results?:, opponent:, seats:}` - `results?` is whether
  that round's results are public.

  `seats` is a seat per board of the match, `%{k:, number:, player:, points:}`
  - `player` the team's own player (a `no`) and `points` what that player
  scored on the board, from `boards[].points`, both `nil` where there is
  nothing to say: a board with no game on the page, or a round whose results
  are withheld (the line-up stays, the score does not).

  Whose seat is whose is read off the board itself - the side whose player is
  on the team's roster - and only when that does not settle it (a player who
  changed team, an unnumbered seat) off the colour convention, team A having
  White on board 1 and every odd board (`matches[].board1_white_team`).
  """
  def team_lineups(payload, %{} = team) do
    no = Map.get(team, "no")
    roster = team |> Map.get("players", []) |> List.wrap() |> MapSet.new()

    for round <- rounds(payload),
        match <- matches(round),
        match_side(match, no) != nil do
      bye? = Map.get(match, "bye") == true
      public? = results_public?(round)

      seats =
        if bye? do
          []
        else
          index = board_index(round)

          for slot <- match_slots(index, match),
              do: lineup_seat(slot, match, no, roster, public?)
        end

      %{
        round: number_of(round),
        match: match,
        bye?: bye?,
        results?: public?,
        opponent: match_opponent(match, no),
        seats: seats
      }
    end
  end

  defp lineup_seat(%{board: nil} = slot, _match, _no, _roster, _public?),
    do: %{k: slot.k, number: slot.number, player: nil, points: nil}

  defp lineup_seat(%{board: board} = slot, match, no, roster, public?) do
    white = Map.get(board, "white")
    black = Map.get(board, "black")

    colour =
      cond do
        white in roster and black not in roster -> :white
        black in roster and white not in roster -> :black
        team_white_on?(match, no, slot.k) -> :white
        true -> :black
      end

    points =
      with true <- public?, {w, b} <- board_points(board) do
        if colour == :white, do: w, else: b
      else
        _withheld_or_unknown -> nil
      end

    %{
      k: slot.k,
      number: slot.number,
      player: if(colour == :white, do: white, else: black),
      points: points
    }
  end

  # Whether `no` has White on board `k` of `match`: the side with White on
  # board 1 has it on every odd board.
  defp team_white_on?(match, no, k) do
    first_white =
      case Map.get(match, "board1_white_team") do
        team when is_integer(team) -> team
        _absent -> Map.get(match, "team_a")
      end

    first_white == no == (rem(k, 2) == 1)
  end

  @doc """
  The roster of one team as the team page prints it, in roster order:
  `%{player:, board:, games:, points:}`.

  `board` is the board the player sat at most often (the lower one on a tie,
  `board_stats` own rule), `games` and `points` what they scored for the
  team. From `board_stats` when the snapshot has it for the player, and
  otherwise from the team's `lineups` (`team_lineups/2`); `nil` for whatever
  neither knows - a reserve who has not played, a round whose results are not
  public.
  """
  def team_roster_rows(payload, %{} = team, lineups) do
    stats = Map.new(board_stats(payload), &{Map.get(&1, "player"), &1})
    played = lineup_record(lineups)

    for player <- team_roster(payload, team) do
      no = Map.get(player, "no")

      case Map.get(stats, no) do
        %{} = row ->
          %{
            player: player,
            board: Map.get(row, "board"),
            games: Map.get(row, "games"),
            points: Map.get(row, "points")
          }

        nil ->
          seats = Map.get(played, no, [])

          %{
            player: player,
            board: most_played_board(seats),
            games: if(seats == [], do: nil, else: length(seats)),
            points: lineup_points(seats)
          }
      end
    end
  end

  # player no => their seats, across the line-ups.
  defp lineup_record(lineups) do
    lineups
    |> Enum.flat_map(& &1.seats)
    |> Enum.reject(&is_nil(&1.player))
    |> Enum.group_by(& &1.player)
  end

  defp most_played_board([]), do: nil

  defp most_played_board(seats) do
    seats
    |> Enum.frequencies_by(& &1.k)
    |> Enum.min_by(fn {k, count} -> {-count, k} end)
    |> elem(0)
  end

  defp lineup_points(seats) do
    case Enum.reject(seats, &is_nil(&1.points)) do
      [] -> nil
      scored -> scored |> Enum.map(& &1.points) |> Enum.sum()
    end
  end

  @doc """
  The teams by board: a row per team (the order of `team_list/1`), a column
  per board number that any `board_stats` row names, and in each cell the
  players of that team whose own board it is - `%{player:, row:}` with `row`
  the `board_stats` entry. A cell is a list because two players can share a
  board number when a reserve took over; it is empty when nobody did.

  `%{boards: [integer], rows: [%{no:, team:, rank:, cells: %{board => [..]}}]}`.
  Empty `boards` until standings have been published (`board_stats` is empty
  until then).
  """
  def team_board_grid(payload) do
    stats = board_stats(payload)
    players = players_by_no(payload)

    boards =
      stats
      |> Enum.map(&Map.get(&1, "board"))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.sort()

    by_team = Enum.group_by(stats, &Map.get(&1, "team"))

    rows =
      for entry <- team_list(payload) do
        cells =
          by_team
          |> Map.get(entry.no, [])
          |> Enum.group_by(&Map.get(&1, "board"))
          |> Map.new(fn {board, rows} ->
            {board,
             rows
             |> Enum.sort_by(&{-(Map.get(&1, "games") || 0), Map.get(&1, "player")})
             |> Enum.map(&%{player: Map.get(players, Map.get(&1, "player")), row: &1})
             |> Enum.reject(&is_nil(&1.player))}
          end)

        %{no: entry.no, team: entry.team, rank: entry.rank, cells: cells}
      end

    %{boards: boards, rows: rows}
  end

  @doc """
  The team cross-table by round, for a team Swiss: a row per team (in the
  order of `team_list/1`), a column per round the standings reach whose
  results are public (`crosstable_rounds/1`), and in each cell the match that
  team played that round, from its own side:

      %{round:, match:, bye?:, opponent:, colour:, gp:, opp_gp:, mp:,
        total_mp:, total_gp:}

  `colour` is the team's colour on board 1. `total_mp`/`total_gp` are the
  running totals through that round, added up here from the matches' own
  figures; they go `nil` from the first match whose figure is not known yet,
  and stay `nil`, rather than carry on as if it were zero. A round the team
  was not scheduled in is a `nil` cell. The final MP and GP columns are the
  standings' own, never these sums.

  `%{rounds: [integer], rows: [%{no:, team:, rank:, mp:, gp:, cells: [cell | nil]}]}`.
  """
  def team_round_crosstable(payload) do
    by_round = rounds_by_number(payload)

    numbers =
      payload
      |> crosstable_rounds()
      |> Enum.filter(&(by_round |> Map.fetch!(&1) |> matches() != []))

    rows =
      for entry <- team_list(payload) do
        {cells, _running} =
          Enum.map_reduce(numbers, {0.0, 0.0}, fn number, running ->
            match =
              by_round
              |> Map.fetch!(number)
              |> matches()
              |> Enum.find(&(match_side(&1, entry.no) != nil))

            round_cell(number, match, entry.no, running)
          end)

        %{
          no: entry.no,
          team: entry.team,
          rank: entry.rank,
          mp: entry.mp,
          gp: entry.gp,
          cells: cells
        }
      end

    %{rounds: numbers, rows: rows}
  end

  defp round_cell(_number, nil, _no, running), do: {nil, running}

  defp round_cell(number, match, no, {total_mp, total_gp}) do
    {gp, mp} = match_points_for(match, no)
    bye? = Map.get(match, "bye") == true

    opp_gp =
      case match_side(match, no) do
        :a -> get_in(match, ["game_points", "b"])
        :b -> get_in(match, ["game_points", "a"])
      end

    total_mp = add(total_mp, mp)
    total_gp = add(total_gp, gp)

    cell = %{
      round: number,
      match: match,
      bye?: bye?,
      opponent: match_opponent(match, no),
      colour: if(bye?, do: nil, else: board1_colour(match, no)),
      gp: gp,
      opp_gp: if(bye?, do: nil, else: opp_gp),
      mp: mp,
      total_mp: total_mp,
      total_gp: total_gp
    }

    {cell, {total_mp, total_gp}}
  end

  # A running total that has met an unknown figure stays unknown.
  defp add(nil, _value), do: nil
  defp add(_total, nil), do: nil
  defp add(total, value) when is_number(value), do: total + value
  defp add(_total, _junk), do: nil

  defp board1_colour(match, no) do
    case Map.get(match, "board1_white_team") do
      ^no -> :white
      team when is_integer(team) -> :black
      _absent -> if Map.get(match, "team_a") == no, do: :white, else: :black
    end
  end

  defp number_of(round), do: Map.get(round, "number")

  defp object(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      object when is_map(object) -> object
      _absent_or_wrong_shape -> %{}
    end
  end

  defp object(_not_a_map, _key), do: %{}

  defp list(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      list when is_list(list) -> list
      _absent_or_wrong_shape -> []
    end
  end

  defp list(_not_a_map, _key), do: []

  defp string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent_or_not_a_string -> nil
    end
  end

  defp string(_not_a_map, _key), do: nil
end
