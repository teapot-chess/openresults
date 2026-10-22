defmodule OpenResults.Repo.Migrations.AddReferenceToReports do
  use Ecto.Migration

  @moduledoc """
  The number a reporter is handed so they can ask what became of their report.
  Null for the reports sent before it existed: nobody holds a number for them.
  Unique, because the lookup page finds a report by nothing else.
  """

  def change do
    alter table(:reports) do
      add :reference, :string
    end

    create unique_index(:reports, [:reference])
  end
end
