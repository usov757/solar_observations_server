defmodule SolarObservations.Event do
  @moduledoc """
  Контекст для работы с сессиями наблюдений и их событиями.
  """

  alias SolarObservations.{ObservingSession, Repo, SessionEvent}
  import Ecto.Query

  @session_preloads [:mount, :session_events]

  # --- ObservingSession ---

  def list_sessions do
    Repo.all(ObservingSession) |> Repo.preload(@session_preloads)
  end

  def list_sessions_by_mount(mount_id) do
    Repo.all(from s in ObservingSession, where: s.mount_id == ^mount_id, preload: ^@session_preloads)
  end

  def get_session!(id), do: Repo.get!(ObservingSession, id) |> Repo.preload(@session_preloads)

  def create_session(attrs) do
    with {:ok, session} <- %ObservingSession{} |> ObservingSession.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(session, @session_preloads)}
    end
  end

  def update_session(%ObservingSession{} = session, attrs) do
    with {:ok, session} <- session |> ObservingSession.changeset(attrs) |> Repo.update() do
      {:ok, Repo.preload(session, @session_preloads)}
    end
  end

  def delete_session(%ObservingSession{} = session), do: Repo.delete(session)

  def end_session(%ObservingSession{} = session) do
    update_session(session, %{ended_at: DateTime.utc_now(), status: "completed"})
  end

  def abort_session(%ObservingSession{} = session) do
    update_session(session, %{status: "aborted"})
  end

  # --- SessionEvent ---

  def list_events do
    Repo.all(SessionEvent) |> Repo.preload(:observing_session)
  end

  def list_events_by_session(session_id) do
    get_session!(session_id)
    Repo.all(from e in SessionEvent, where: e.observing_session_id == ^session_id, preload: :observing_session)
  end

  def get_event!(id), do: Repo.get!(SessionEvent, id) |> Repo.preload(:observing_session)

  def create_event(attrs) do
    with {:ok, event} <- %SessionEvent{} |> SessionEvent.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(event, :observing_session)}
    end
  end

  def update_event(%SessionEvent{} = event, attrs) do
    with {:ok, event} <- event |> SessionEvent.changeset(attrs) |> Repo.update() do
      {:ok, Repo.preload(event, :observing_session)}
    end
  end

  def delete_event(%SessionEvent{} = event), do: Repo.delete(event)

  def create_typed_event(session_id, event_type, params) do
    attrs = %{
      occurred_at: DateTime.utc_now(),
      event_type: event_type,
      raw_command: params["raw_command"],
      raw_response: params["raw_response"],
      success: Map.get(params, "success", event_type != "error"),
      message: params["message"],
      observing_session_id: session_id
    }

    create_event(attrs)
  end
end
