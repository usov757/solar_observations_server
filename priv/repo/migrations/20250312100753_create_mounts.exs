defmodule SolarObservations.Repo.Migrations.CreateMounts do
  use Ecto.Migration

  def change do
    create table(:mounts) do
      add :name,             :string, null: false
      add :port,             :string          # "/dev/ttyUSB0"
      add :connection_type,  :string, default: "serial"

      # Кэш от контроллера (:a :b :g :D)
      add :cpr_ra,           :bigint
      add :timer_freq,       :bigint
      add :tracking_period,  :bigint

      # Геолокация
      add :latitude,         :decimal, precision: 10, scale: 6
      add :longitude,        :decimal, precision: 10, scale: 6

      # Параметры соединения
      add :baud_rate,        :integer, default: 9600
      add :reconnect_interval, :integer, default: 5000

      add :initialized,      :boolean, default: false
      timestamps()
    end

    create index(:mounts, [:name])
  end
end
