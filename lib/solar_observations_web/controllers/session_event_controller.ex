defmodule SolarObservationsWeb.SessionEventController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Event

  def index(conn, _params) do
    render(conn, :index, events: Event.list_events())
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, event: Event.get_event!(id))
  end

  def create(conn, %{"session_event" => params}) do
    with {:ok, event} <- Event.create_event(params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/session_events/#{event}")
      |> render(:show, event: event)
    end
  end

  def update(conn, %{"id" => id, "session_event" => params}) do
    with {:ok, event} <- Event.update_event(Event.get_event!(id), params) do
      render(conn, :show, event: event)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Event.delete_event(Event.get_event!(id)) do
      send_resp(conn, :no_content, "")
    end
  end

  def by_session(conn, %{"session_id" => session_id}) do
    render(conn, :index, events: Event.list_events_by_session(session_id))
  end

  def create_mount_command(conn, %{"session_id" => session_id, "mount_command" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "mount_command", params) do
      render(conn, :show, event: event)
    end
  end

  def create_correction(conn, %{"session_id" => session_id, "correction" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "correction", params) do
      render(conn, :show, event: event)
    end
  end

  def create_error(conn, %{"session_id" => session_id, "error" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "error", params) do
      render(conn, :show, event: event)
    end
  end
end
