defmodule OpenResults.Repo.Migrations.AddLabelToInstallations do
  use Ecto.Migration

  def change do
    # The operator's private name for an installation, shown in the admin
    # panel and nowhere else. See `OpenResults.Moderation.put_installation_label/3`.
    alter table(:installations) do
      add :label, :text
    end
  end
end
