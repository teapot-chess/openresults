defmodule OpenResultsWeb.ErrorHTMLTest do
  use OpenResultsWeb.ConnCase, async: true

  alias OpenResultsWeb.ErrorHTML

  defp page(template, accept_language \\ nil) do
    conn = Plug.Test.conn(:get, "/nowhere")

    conn =
      if accept_language,
        do: Plug.Conn.put_req_header(conn, "accept-language", accept_language),
        else: conn

    template |> ErrorHTML.render(%{conn: conn}) |> Phoenix.HTML.safe_to_string()
  end

  test "a 404 is a page with a sentence and a way back, not two bare words" do
    doc = LazyHTML.from_document(page("404.html"))

    assert LazyHTML.text(LazyHTML.query(doc, "#error-heading")) == "Page not found"
    assert [href] = LazyHTML.attribute(LazyHTML.query(doc, "#error-home"), "href")
    assert href == "/"
    assert LazyHTML.attribute(LazyHTML.query(doc, "html"), "lang") == ["en"]
  end

  test "a 500 says the fault is ours and links home" do
    doc = LazyHTML.from_document(page("500.html"))

    assert LazyHTML.text(LazyHTML.query(doc, "#error-heading")) == "Something went wrong"
    assert LazyHTML.query(doc, "#error-home") |> Enum.count() == 1
  end

  test "it answers in the reader's language" do
    doc = LazyHTML.from_document(page("404.html", "nl-BE,nl;q=0.9"))

    assert LazyHTML.attribute(LazyHTML.query(doc, "html"), "lang") == ["nl"]
    refute LazyHTML.text(LazyHTML.query(doc, "#error-heading")) == "Page not found"
  end

  test "an unknown route answers with it" do
    conn = get(build_conn(), "/certainly/not/a/route")

    assert conn.status == 404
    assert conn.resp_body =~ ~s(id="error-home")
  end

  test "other templates keep the plain status message" do
    assert ErrorHTML.render("403.html", %{}) == "Forbidden"
  end
end
