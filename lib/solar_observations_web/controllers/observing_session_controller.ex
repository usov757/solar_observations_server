defmodule SolarObservationsWeb.ObservingSessionController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Event

  def index(conn, _params) do
    render(conn, :index, sessions: Event.list_sessions())
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, session: Event.get_session!(id))
  end

  def create(conn, %{"observing_session" => params}) do
    with {:ok, session} <- Event.create_session(params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/observing_sessions/#{session}")
      |> render(:show, session: session)
    end
  end

  def update(conn, %{"id" => id, "observing_session" => params}) do
    with {:ok, session} <- Event.update_session(Event.get_session!(id), params) do
      render(conn, :show, session: session)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Event.delete_session(Event.get_session!(id)) do
      send_resp(conn, :no_content, "")
    end
  end

  def by_mount(conn, %{"mount_id" => mount_id}) do
    render(conn, :index, sessions: Event.list_sessions_by_mount(mount_id))
  end

  def end_session(conn, %{"id" => id}) do
    with {:ok, session} <- Event.end_session(Event.get_session!(id)) do
      render(conn, :show, session: session)
    end
  end

  def abort(conn, %{"id" => id}) do
    with {:ok, session} <- Event.abort_session(Event.get_session!(id)) do
      render(conn, :show, session: session)
    end
  end
end
