defmodule SolarObservations.SessionEvent do
  @moduledoc """
  Модель для представления событий сессии наблюдений.

  Содержит информацию о командах, исправлениях, ошибках и системных событиях.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias SolarObservations.ObservingSession

  schema "session_events" do
    field :occurred_at, :utc_datetime
    field :event_type, :string
    field :raw_command, :string
    field :raw_response, :string
    field :success, :boolean, default: true
    field :message, :string

    belongs_to :observing_session, ObservingSession

    timestamps()
  end

  @doc false
  def changeset(session_event, attrs) do
    session_event
    |> cast(attrs, [
      :occurred_at,
      :event_type,
      :raw_command,
      :raw_response,
      :success,
      :message,
      :observing_session_id
    ])
    |> validate_required([:occurred_at, :event_type, :observing_session_id])
    |> validate_inclusion(:event_type, ["mount_command", "correction", "error", "system"])
    |> foreign_key_constraint(:observing_session_id)
  end
end
