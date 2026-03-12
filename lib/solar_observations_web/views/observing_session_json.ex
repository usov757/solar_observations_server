defmodule SolarObservationsWeb.ObservingSessionJSON do
  @moduledoc """
  View-модуль для сериализации данных сессий наблюдений в JSON.
  """

  alias SolarObservations.ObservingSession

  def index(%{sessions: sessions}), do: %{sessions: Enum.map(sessions, &session/1)}
  def show(%{session: session}), do: session(session)

  def errors(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  # --- Приватные функции ---

  defp session(%ObservingSession{} = session) do
    %{
      id: session.id,
      started_at: session.started_at,
      ended_at: session.ended_at,
      status: session.status,
      target_name: session.target_name,
      notes: session.notes,
      mount_id: session.mount_id,
      mount: mount_summary(session.mount),
      session_events: Enum.map(session.session_events, &session_event/1),
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  defp mount_summary(nil), do: nil
  defp mount_summary(mount), do: %{id: mount.id, name: mount.name}

  defp session_event(event) do
    %{
      id: event.id,
      occurred_at: event.occurred_at,
      event_type: event.event_type,
      raw_command: event.raw_command,
      raw_response: event.raw_response,
      success: event.success,
      message: event.message
    }
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
