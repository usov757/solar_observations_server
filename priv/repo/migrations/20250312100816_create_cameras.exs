defmodule SolarObservations.Repo.Migrations.CreateCameras do
  use Ecto.Migration

  def change do
    create table(:cameras) do
      add :mount_id,         references(:mounts), null: false
      add :name,             :string, null: false   # "ASI174MM"
      add :device_id,        :string               # USB id

      # Параметры съёмки по умолчанию
      add :focal_length_mm,  :decimal, precision: 7, scale: 2
      add :default_exposure, :decimal, precision: 8, scale: 4
      add :default_gain,     :integer

      timestamps()
    end

    create index(:cameras, [:mount_id])
    create index(:cameras, [:name])
  end
end
