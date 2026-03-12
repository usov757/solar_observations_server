defmodule SolarObservations.Repo.Migrations.CreateObservingSessions do
  use Ecto.Migration

  def change do
    create table(:observing_sessions) do
      add :mount_id,    references(:mounts), null: false

      add :started_at,  :utc_datetime, null: false
      add :ended_at,    :utc_datetime            # nil = активен

      add :status,      :string, default: "active"
      # active | completed | aborted | error

      add :target_name, :string                  # "Sun"
      add :notes,       :text
      timestamps()
    end

    create index(:observing_sessions, [:mount_id])
    create index(:observing_sessions, [:status])
    create index(:observing_sessions, [:started_at])
  end
end
