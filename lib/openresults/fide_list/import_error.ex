defmodule OpenResults.FideList.ImportError do
  @moduledoc """
  A downloaded list that cannot become the live one: not a zip, no text in
  it, a header without the columns, or bigger than anybody's rating list.

  Its message is written here, never copied from what failed, so it can be
  shown on the admin page and logged without quoting a line of the file.
  """

  defexception [:message]
end
