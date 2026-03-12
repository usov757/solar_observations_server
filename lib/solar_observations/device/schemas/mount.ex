defmodule SolarObservations.Mount do
  @moduledoc """
  Модель для представления экваториальной монтировки SkyWatcher.

  Содержит конфигурацию монтировки, геолокацию и кэшированные параметры
  контроллера (CPR, timer_freq, tracking_period).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias SolarObservations.Camera
  alias SolarObservations.ObservingSession

  schema "mounts" do
    field :name, :string
    field :port, :string
    field :connection_type, :string, default: "serial"
    field :cpr_ra, :integer
    field :timer_freq, :integer
    field :tracking_period, :integer
    field :latitude, :decimal
    field :longitude, :decimal
    field :baud_rate, :integer, default: 9600
    field :reconnect_interval, :integer, default: 5000
    field :initialized, :boolean, default: false

    has_many :cameras, Camera
    has_many :observing_sessions, ObservingSession

    timestamps()
  end

  @doc false
  def changeset(mount, attrs) do
    mount
    |> cast(attrs, [
      :name,
      :port,
      :connection_type,
      :cpr_ra,
      :timer_freq,
      :tracking_period,
      :latitude,
      :longitude,
      :baud_rate,
      :reconnect_interval,
      :initialized
    ])
    |> validate_required([:name])
    |> validate_inclusion(:connection_type, ["serial", "ethernet", "usb"])
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_number(:baud_rate, greater_than_or_equal_to: 1)
    |> validate_number(:reconnect_interval, greater_than_or_equal_to: 1000)
  end
end
