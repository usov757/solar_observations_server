defmodule SolarObservations.Camera do
  @moduledoc """
  Модель для представления камеры, подключенной к монтировке.

  Содержит конфигурацию камеры и параметры съёмки по умолчанию.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias SolarObservations.Mount

  schema "cameras" do
    field :name, :string
    field :device_id, :string
    field :focal_length_mm, :decimal
    field :default_exposure, :decimal
    field :default_gain, :integer

    belongs_to :mount, Mount

    timestamps()
  end

  @doc false
  def changeset(camera, attrs) do
    camera
    |> cast(attrs, [
      :name,
      :device_id,
      :focal_length_mm,
      :default_exposure,
      :default_gain,
      :mount_id
    ])
    |> validate_required([:name, :mount_id])
    |> validate_number(:focal_length_mm, greater_than: 0)
    |> validate_number(:default_exposure, greater_than: 0)
    |> validate_number(:default_gain, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:mount_id)
  end
end
