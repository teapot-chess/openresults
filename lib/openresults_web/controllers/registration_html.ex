defmodule OpenResultsWeb.RegistrationHTML do
  @moduledoc """
  The entry form's markup.

  Hand written against this app's own stylesheet, like the tables are. The
  scaffold's `<.input>` in `core_components.ex` is styled for daisyUI, which
  `assets/css/app.css` dropped on purpose - tens of kilobytes of component
  library for a site made of four tables and one form, loaded over a playing
  hall's wifi - so using it here would produce controls with class names
  nothing defines.

  The masthead comes from `OpenResultsWeb.TournamentHTML`. This is a page of a
  tournament and should carry the same head as the standings it links back to.
  """

  use OpenResultsWeb, :html

  import OpenResultsWeb.TournamentHTML, only: [masthead: 1, anchor: 2, escaped: 1, date: 1]

  alias OpenResults.Registrations.Entry
  alias OpenResultsWeb.Tournament

  embed_templates "registration_html/*"

  @doc """
  The form itself.

  No `phx-` anything and no JavaScript: this page has to work on the phone of
  somebody standing in a corridor with one bar of signal, and a plain form
  post does. Validation is therefore entirely on the server, and the errors it
  returns have to be worth reading, because a round trip is what they cost.

  Every field is optional except a name and an email. That is not laziness
  about data quality - it is club chess. A player with no rating, no
  federation, no FIDE ID and no club is the ordinary case, and a form that
  demanded them would turn "not known" into "cannot enter".
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :slug, :string, required: true
  attr :fide_search?, :boolean, default: false
  attr :fide_url, :string, default: nil
  attr :rounds, :list, required: true, doc: "the rounds a bye may be requested for"
  attr :alarm, :string, default: nil, doc: "a failure that is not about one field"
  attr :trap, :string, default: nil, doc: "what the honeypot held, when it came back filled"
  attr :trap_name, :string, default: "website"

  def entry_form(assigns) do
    ~H"""
    <.form
      for={@form}
      action={~p"/t/#{@slug}/register"}
      method="post"
      id="registration-form"
      class="entry-form"
      csrf_token={false}
    >
      <%!--
        No CSRF token, deliberately, and the router says why at length: a
        token that nothing on this server verifies would be decoration, and
        verifying one means a session cookie on a site that sets none.
      --%>
      <%!-- `tabindex="-1"` so the page's script can put focus here when the
            form comes back refused: the reader hears what happened before
            anything else, and the next Tab is the first field. --%>
      <p :if={@alarm} class="alarm" role="alert" tabindex="-1">{@alarm}</p>

      <p :if={@form.errors != []} class="alarm" role="alert" tabindex="-1">
        {gettext("Nothing has been sent. Fix what is marked below and send it again.")}
      </p>

      <%!-- The FIDE search, when this deployment can reach an arbiter's
            list. It fills the fields below and is never required: everything
            it would fill can be typed, and a player who is not on the FIDE
            list never uses it at all.

            Sits above the name field rather than beside it because it is the
            first thing to try, and because a player who finds themselves here
            can skip the four fields underneath. --%>
      <%!-- The two `data-` sentences are what the script says to a screen
            reader when a search comes back and when a result fills the form -
            attributes, because a string built in JavaScript is a string
            outside the catalogue. --%>
      <div
        :if={@fide_search?}
        class="fide-search"
        id="fide-search"
        data-endpoint={@fide_url}
        data-found={gettext("Matching players are listed below the search box.")}
        data-filled={
          gettext("Filled in from the FIDE list. Check the fields, and add your email address.")
        }
      >
        <label for="fide-query">{gettext("Find yourself on the FIDE list")}</label>
        <input
          type="search"
          id="fide-query"
          autocomplete="off"
          aria-describedby="fide-hint"
          placeholder={gettext("Start typing your name, or paste your FIDE ID")}
        />
        <p class="hint" id="fide-hint">
          {gettext(
            "Optional. It fills in the fields below - check them, and correct anything that is out of date. If you are not on the FIDE list, just fill them in yourself."
          )}
        </p>
        <ul id="fide-results" class="fide-results" hidden></ul>
        <p id="fide-none" class="hint" hidden>
          {gettext("No match. Fill the fields in below instead.")}
        </p>
      </div>

      <.field
        field={@form[:name]}
        label={gettext("Name")}
        hint={gettext(~s|Surname first, as it should appear on the pairing list: "De Vos, Ilse".|)}
        required
        autocomplete="name"
      />

      <.field
        field={@form[:email]}
        type="email"
        label={gettext("Email")}
        hint={
          gettext(
            "Only the arbiter sees this. It is never shown on these pages and never travels in a published tournament - it is here so they can tell you whether you are in."
          )
        }
        required
        autocomplete="email"
        inputmode="email"
      />

      <.field
        field={@form[:rating]}
        type="text"
        label={gettext("Rating")}
        hint={gettext("Whichever rating you play under. Leave it empty if you have none.")}
        inputmode="numeric"
      />

      <.field
        field={@form[:federation]}
        label={gettext("Federation")}
        hint={gettext("The three-letter FIDE code, like BEL. Leave it empty if you are unsure.")}
        maxlength="3"
        autocomplete="country"
      />

      <.field
        field={@form[:fide_id]}
        type="text"
        label={gettext("FIDE ID")}
        hint={gettext("The number on your FIDE profile, if you have one.")}
        inputmode="numeric"
      />

      <.field
        field={@form[:club]}
        label={gettext("Club")}
        hint={gettext("The club you play for, if any.")}
        autocomplete="organization"
      />

      <.field
        field={@form[:title]}
        label={gettext("Title")}
        options={Entry.titles()}
        hint={gettext("Your FIDE title, if you hold one.")}
      />

      <.field
        field={@form[:birth_year]}
        type="text"
        label={gettext("Birth year")}
        hint={
          gettext(
            "Four digits. Some tournaments have age categories, and the arbiter cannot work one out from a name. Leave it empty if you would rather not say."
          )
        }
        inputmode="numeric"
        maxlength="4"
        autocomplete="bday-year"
      />

      <.field
        field={@form[:national_id]}
        type="text"
        label={gettext("National ID")}
        hint={
          gettext(
            "Your member number at your national federation, if you have one - in Belgium, your KBSB/FRBE number."
          )
        }
        maxlength="21"
      />

      <.byes_field :if={@rounds != []} field={@form[:requested_byes]} rounds={@rounds} />

      <%!-- The honeypot - see `RegistrationController`'s `@trap`. Hidden from
            people by `.trap` (off-screen, not `display: none`, which some
            bots check for) and from assistive technology by `aria-hidden`
            and `tabindex="-1"`. When it comes back filled it is shown, with
            its own label, because a person whose browser filled it has to be
            able to see what to clear. --%>
      <div
        class={["field", is_nil(@trap) && "trap", @trap && "field-wrong"]}
        aria-hidden={is_nil(@trap) && "true"}
      >
        <label for="registration_trap">{gettext("Leave this empty")}</label>
        <input
          type="text"
          id="registration_trap"
          name={"registration[#{@trap_name}]"}
          value={@trap || ""}
          autocomplete="off"
          tabindex={is_nil(@trap) && "-1"}
        />
      </div>

      <div class="actions">
        <button type="submit" id="registration-submit">{gettext("Send to the arbiter")}</button>
        <a href={~p"/t/#{@slug}"} class="cancel">{gettext("Cancel")}</a>
      </div>

      <p class="hint form-terms">
        <a href={~p"/terms"} id="registration-terms">
          {gettext("How this site handles what you send: terms and privacy")}
        </a>
      </p>
    </.form>
    """
  end

  @doc """
  What a person should know before filling the form in: when entries close,
  and how full the field is. Nothing when the arbiter set neither.
  """
  attr :payload, :map, required: true
  attr :places, :map, default: nil, doc: "%{taken: n, max: n}, or nil when uncapped"

  def entry_facts(assigns) do
    assigns =
      assigns
      |> assign(:closes_at, Tournament.registration_closes_at(assigns.payload))
      |> assign(:fee, Tournament.entry_fee(assigns.payload))

    ~H"""
    <ul :if={@closes_at || @places || @fee} class="entry-facts" id="entry-facts">
      <li :if={@fee} id="entry-fee">
        <span :if={@fee.amount}>
          {gettext("Entry fee: %{amount}.", amount: fee_amount(@fee))}
        </span>
        <span :if={@fee.note}>{@fee.note}</span>
      </li>
      <li :if={@closes_at}>
        {gettext("Entries close on %{when}.", when: instant(@closes_at))}
      </li>
      <li :if={@places} id="entry-places">
        {gettext("%{taken} of %{max} places taken, counting entries the arbiter has not decided yet.",
          taken: @places.taken,
          max: @places.max
        )}
      </li>
    </ul>
    """
  end

  @doc """
  Who has entered so far, when the arbiter allows it.

  Built from `players[]` - the entry list the snapshot already publishes -
  with the same `display` switches as the standings, so a column the arbiter
  hid there is hidden here. Entries still waiting for the arbiter are listed
  by name, after the players and marked unconfirmed, when the arbiter's app
  sends them (`Tournament.pending_entrants/1`) - the arbiter's Discard takes
  one off the next snapshot. And no email, ever - `players[]` has none.
  """
  attr :payload, :map, required: true
  attr :places, :map, default: nil

  def entry_list(assigns) do
    payload = assigns.payload

    assigns =
      assigns
      |> assign(:players, entrants(payload))
      |> assign(:pending, Tournament.pending_entrants(payload))
      |> assign(:rating?, Tournament.show?(payload, "rating"))
      |> assign(:title?, Tournament.show?(payload, "title"))
      |> assign(:federation?, Tournament.show?(payload, "federation"))
      |> assign(:flags?, Tournament.flags?(payload))
      |> assign(:club?, Tournament.show?(payload, "club"))

    ~H"""
    <section id="entry-list" aria-labelledby="entry-list-heading">
      <h2 id="entry-list-heading">
        {gettext("Entered so far")}
        <span class="quiet">{length(@players)}</span>
        <span :if={@pending != []} id="entry-pending-count" class="quiet">
          {gettext("+ %{count} unconfirmed", count: length(@pending))}
        </span>
      </h2>

      <p :if={@players == [] and @pending == []} class="empty">
        {gettext("Nobody is on the entry list yet.")}
      </p>

      <table :if={@players != [] or @pending != []} class="standings entry-list">
        <thead>
          <tr>
            <th scope="col" class="num">#</th>
            <th scope="col">{gettext("Name")}</th>
            <th :if={@rating?} scope="col" class="num">{gettext("Rating")}</th>
            <th :if={@federation?} scope="col">{gettext("Federation")}</th>
            <th :if={@club?} scope="col">{gettext("Club")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{player, index} <- Enum.with_index(@players, 1)}>
            <td class="num">{index}</td>
            <td>
              <span :if={@title? and is_binary(player["title"])} class="title">
                {player["title"]}
              </span>
              {player["name"]}
            </td>
            <td :if={@rating?} class="num">{rating(player["rating"])}</td>
            <td :if={@federation?}>
              <Flags.flag :if={@flags?} code={player["federation"]} />
              {player["federation"]}
            </td>
            <td :if={@club?}>{player["club"]}</td>
          </tr>
          <tr :for={name <- @pending} class="pending">
            <td class="num"></td>
            <td>
              {name}
              <span class="tag">{gettext("unconfirmed")}</span>
            </td>
            <td :if={@rating?}></td>
            <td :if={@federation?}></td>
            <td :if={@club?}></td>
          </tr>
        </tbody>
      </table>

      <p class="footnote">
        <%= if @pending == [] do %>
          {gettext("Players the arbiter has entered.")}
        <% else %>
          {gettext(
            "Players the arbiter has entered, and entries still waiting for a decision, marked unconfirmed. An unconfirmed entry is a request, not a place."
          )}
        <% end %>
      </p>
    </section>
    """
  end

  # Strongest first, the way an entry list is usually read, then by name.
  # A hidden rating still sorts: the order says no more than the pairing
  # numbers on the round pages already do.
  defp entrants(payload) do
    payload
    |> Tournament.players()
    |> Enum.filter(&is_binary(&1["name"]))
    |> Enum.sort_by(fn player ->
      rating = if is_integer(player["rating"]), do: player["rating"], else: 0
      {-rating, player["name"]}
    end)
  end

  # "12.50 EUR". The amount and the currency travel apart and are put back
  # together here, because how a currency is written is a page's business.
  defp fee_amount(%{amount: amount, currency: nil}), do: amount
  defp fee_amount(%{amount: amount, currency: currency}), do: "#{amount} #{currency}"

  defp rating(value) when is_integer(value) and value > 0, do: value
  defp rating(_unrated), do: nil

  @doc """
  An instant from the snapshot, as a date and a time in UTC.

  UTC and said so: the arbiter set it on a machine this server knows nothing
  about, and a time with no zone beside it is a time somebody reads wrong.
  """
  def instant(%DateTime{} = at) do
    # `Tournament` parses these with `DateTime.from_iso8601/1`, which always
    # answers in UTC whatever offset the string carried.
    gettext("%{date}, %{time} UTC",
      date: date(Date.to_iso8601(DateTime.to_date(at))),
      time: Calendar.strftime(at, "%H:%M")
    )
  end

  def instant(_absent), do: nil

  @doc """
  One labelled field, with its hint and whatever went wrong with it.

  The error sits under the input rather than in a list at the top, because a
  list at the top makes somebody count fields to work out which one it meant.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :hint, :string, default: nil

  attr :rest, :global, include: ~w(autocomplete inputmode maxlength pattern placeholder required)

  attr :options, :list,
    default: nil,
    doc: "renders a <select> instead of an <input>; the empty option is added for you"

  attr :blank, :string, default: nil, doc: "label for the empty option of a select"

  def field(assigns) do
    field = assigns.field
    errors = Enum.map(field.errors, &translate_error/1)

    # The error before the hint: what is wrong is the first thing to hear
    # after the field's name, the same order the page shows them in.
    described_by =
      [errors != [] && "#{field.id}_error", assigns.hint && "#{field.id}_hint"]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    assigns =
      assigns
      |> assign(:errors, errors)
      |> assign(:described_by, if(described_by == "", do: nil, else: described_by))
      # Defaulted here rather than in the `attr`, because an attribute default
      # is evaluated where the component is compiled and a translation has to
      # be looked up where it is rendered.
      |> assign(:blank, assigns.blank || gettext("None"))

    ~H"""
    <div class={["field", @errors != [] && "field-wrong"]}>
      <%!-- The word is for the eye. The input's own `required` attribute is
            what a screen reader announces, and reading both gave "Name
            required, edit, required". --%>
      <label for={@field.id}>
        {@label}
        <span :if={@rest[:required]} class="required" aria-hidden="true">{gettext("required")}</span>
      </label>

      <select
        :if={@options}
        id={@field.id}
        name={@field.name}
        aria-describedby={@described_by}
        aria-invalid={@errors != [] && "true"}
      >
        <%!-- Always first and always selected-able. A closed vocabulary with
              no way to say "none of these" turns an optional field into a
              required one by accident. --%>
        <option value="">{@blank}</option>
        <option
          :for={option <- @options}
          value={option}
          selected={to_string(@field.value) == option}
        >
          {option}
        </option>
      </select>

      <input
        :if={is_nil(@options)}
        type={@type}
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        aria-describedby={@described_by}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />

      <p :if={@errors != []} class="wrong" id={"#{@field.id}_error"}>
        {Enum.join(@errors, ". ")}
      </p>
      <p :if={@hint} class="hint" id={"#{@field.id}_hint"}>{@hint}</p>
    </div>
    """
  end

  @doc """
  The rounds a player can ask to sit out.

  Boxes rather than a text field, because the tournament already told us how
  many rounds it has and a list somebody types is a list somebody mistypes.
  Offered only when the rounds are known - a tournament whose payload does not
  say how long it is gets no bye question at all, which is honest, where a
  free-text box would be inviting an answer nobody can check.

  The wording is the whole design constraint in one sentence: ticking a box is
  a request, and the arbiter grants byes.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :rounds, :list, required: true

  def byes_field(assigns) do
    field = assigns.field
    errors = Enum.map(field.errors, &translate_error/1)

    # The value comes back as strings after a failed submission and as
    # integers from a changeset, so both are compared as text.
    chosen =
      case field.value do
        values when is_list(values) -> Enum.map(values, &to_string/1)
        _absent_or_wrong_shape -> []
      end

    assigns =
      assigns
      |> assign(:errors, errors)
      |> assign(:chosen, chosen)
      |> assign(
        :described_by,
        [errors != [] && "#{field.id}_error", "#{field.id}_hint"]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
      )

    ~H"""
    <%!-- The error and the hint belong to the group, not to one box, so the
          fieldset carries them: a screen reader reads them on the way in. --%>
    <fieldset class={["field", @errors != [] && "field-wrong"]} aria-describedby={@described_by}>
      <legend>{gettext("Rounds you already know you cannot play")}</legend>

      <div class="checks">
        <label :for={round <- @rounds} class="check">
          <input
            type="checkbox"
            name={@field.name <> "[]"}
            value={round}
            checked={to_string(round) in @chosen}
          />
          <span>{round}</span>
        </label>
      </div>

      <p :if={@errors != []} class="wrong" id={"#{@field.id}_error"}>{Enum.join(@errors, ". ")}</p>
      <p class="hint" id={"#{@field.id}_hint"}>
        {gettext(
          "Asking is not the same as getting. What a missed round is worth - a half point, nothing at all - is the arbiter's decision and their tournament's rules, not this form's."
        )}
      </p>
    </fieldset>
    """
  end
end
