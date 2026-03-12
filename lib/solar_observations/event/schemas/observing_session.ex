defmodule SolarObservations.ObservingSession do
  @moduledoc """
  Модель для представления сессии наблюдений.

  Содержит информацию о сессии наблюдений, включая целевую цель,
  статус и временные метки.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias SolarObservations.Mount
  alias SolarObservations.SessionEvent

  schema "observing_sessions" do
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :status, :string, default: "active"
    field :target_name, :string
    field :notes, :string

    belongs_to :mount, Mount
    has_many :session_events, SessionEvent

    timestamps()
  end

  @doc false
  def changeset(observing_session, attrs) do
    observing_session
    |> cast(attrs, [
      :started_at,
      :ended_at,
      :status,
      :target_name,
      :notes,
      :mount_id
    ])
    |> validate_required([:started_at, :mount_id])
    |> validate_inclusion(:status, ["active", "completed", "aborted", "error"])
    |> validate_datetime_range()
    |> foreign_key_constraint(:mount_id)
  end

  defp validate_datetime_range(changeset) do
    started_at = get_field(changeset, :started_at)
    ended_at = get_field(changeset, :ended_at)

    if started_at && ended_at && DateTime.compare(started_at, ended_at) != :lt do
      add_error(changeset, :ended_at, "must be after started_at")
    else
      changeset
    end
  end
end
