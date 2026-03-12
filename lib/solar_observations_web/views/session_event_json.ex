defmodule SolarObservationsWeb.SessionEventJSON do
  @moduledoc """
  View-модуль для сериализации данных событий сессий наблюдений в JSON.
  """

  alias SolarObservations.SessionEvent

  def index(%{events: events}), do: %{session_events: Enum.map(events, &event/1)}
  def show(%{event: event}), do: event(event)

  def errors(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  # --- Приватные функции ---

  defp event(%SessionEvent{} = event) do
    %{
      id: event.id,
      occurred_at: event.occurred_at,
      event_type: event.event_type,
      raw_command: event.raw_command,
      raw_response: event.raw_response,
      success: event.success,
      message: event.message,
      observing_session_id: event.observing_session_id,
      observing_session: session_summary(event.observing_session),
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  defp session_summary(nil), do: nil
  defp session_summary(session), do: %{id: session.id, target_name: session.target_name}

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
