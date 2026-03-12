defmodule SolarObservations.Repo.Migrations.CreateSessionEvents do
  use Ecto.Migration

  def change do
    create table(:session_events) do
      add :observing_session_id, references(:observing_sessions), null: false

      add :occurred_at,   :utc_datetime, null: false
      add :event_type,    :string, null: false
      # mount_command | correction | error | system

      add :raw_command,   :string        # ":G110\r"
      add :raw_response,  :string        # "=\r"
      add :success,       :boolean, default: true
      add :message,       :string
      timestamps()
    end

    create index(:session_events, [:observing_session_id, :occurred_at])
    create index(:session_events, [:event_type])
  end
end
