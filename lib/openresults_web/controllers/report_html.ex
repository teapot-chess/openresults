defmodule OpenResultsWeb.ReportHTML do
  @moduledoc """
  The report form's markup.

  Built from the entry form's own pieces (`OpenResultsWeb.RegistrationHTML`)
  so the two forms on this site look and fail the same way: plain HTML, no
  JavaScript, errors under the field they are about.
  """

  use OpenResultsWeb, :html

  import OpenResultsWeb.TournamentHTML, only: [masthead: 1]
  import OpenResultsWeb.RegistrationHTML, only: [field: 1]

  alias OpenResults.Reports
  alias OpenResults.Reports.Report

  embed_templates "report_html/*"

  @doc """
  The reason, as a translated label. Each code is its own msgid so a
  translator sees a whole phrase.
  """
  def reason_label("wrong_or_fake_results"), do: gettext("The results are wrong or invented")

  def reason_label("personal_data"),
    do: gettext("It shows personal data that should not be public")

  def reason_label("spam_or_offensive"), do: gettext("It is spam or offensive")
  def reason_label("other"), do: gettext("Something else")

  @doc "The form."
  attr :form, Phoenix.HTML.Form, required: true
  attr :slug, :string, required: true

  def report_form(assigns) do
    reason = assigns.form[:reason]

    assigns =
      assigns
      |> assign(:reason, reason)
      |> assign(:reason_errors, Enum.map(reason.errors, &translate_error/1))
      |> assign(:details, assigns.form[:details])
      |> assign(:details_errors, Enum.map(assigns.form[:details].errors, &translate_error/1))

    ~H"""
    <.form
      for={@form}
      action={~p"/t/#{@slug}/report"}
      method="post"
      id="report-form"
      class="entry-form"
      csrf_token={false}
    >
      <%!-- No CSRF token, for the entry form's reason: see the router. --%>
      <p :if={@form.errors != []} class="alarm" role="alert" tabindex="-1">
        {gettext("Nothing has been sent. Fix what is marked below and send it again.")}
      </p>

      <%!-- `required` on the radios is what a screen reader announces as
            required; the visible word beside the legend is for the eye, and
            hidden from the reader so it is not said twice. The error is tied
            to the group, which is what it is about. --%>
      <fieldset
        class={["field", @reason_errors != [] && "field-wrong"]}
        aria-describedby={@reason_errors != [] && "#{@reason.id}_error"}
      >
        <legend>
          {gettext("What is wrong with this page?")}
          <span class="required" aria-hidden="true">{gettext("required")}</span>
        </legend>

        <div class="radios">
          <label :for={code <- Report.reasons()} class="radio">
            <input
              type="radio"
              name={@reason.name}
              value={code}
              checked={to_string(@reason.value) == code}
              required
            />
            <span>{reason_label(code)}</span>
          </label>
        </div>

        <p :if={@reason_errors != []} class="wrong" id={"#{@reason.id}_error"}>
          {Enum.join(@reason_errors, ". ")}
        </p>
      </fieldset>

      <div class={["field", @details_errors != [] && "field-wrong"]}>
        <label for={@details.id}>{gettext("Details")}</label>
        <textarea
          id={@details.id}
          name={@details.name}
          maxlength={Report.max_details()}
          aria-describedby={
            if(@details_errors != [],
              do: "#{@details.id}_error #{@details.id}_hint",
              else: "#{@details.id}_hint"
            )
          }
          aria-invalid={@details_errors != [] && "true"}
        >{Phoenix.HTML.Form.normalize_value("textarea", @details.value)}</textarea>
        <p :if={@details_errors != []} class="wrong" id={"#{@details.id}_error"}>
          {Enum.join(@details_errors, ". ")}
        </p>
        <p class="hint" id={"#{@details.id}_hint"}>
          {gettext(
            "Which results, which player, what should not be there. Up to 2000 characters. Please do not repeat personal data here that is not already on the page."
          )}
        </p>
      </div>

      <.field
        field={@form[:contact_email]}
        type="email"
        label={gettext("Your email address")}
        hint={
          gettext(
            "Optional. Only the operator of this site sees it, and only uses it if they need to ask you something about this report."
          )
        }
        autocomplete="email"
        inputmode="email"
      />

      <div class="actions">
        <button type="submit" id="report-submit">{gettext("Send the report")}</button>
        <a href={~p"/t/#{@slug}"} class="cancel">{gettext("Cancel")}</a>
      </div>

      <p class="hint form-terms">
        <a href={~p"/terms"} id="report-terms">
          {gettext("How this site handles what you send: terms and privacy")}
        </a>
      </p>
    </.form>
    """
  end
end
