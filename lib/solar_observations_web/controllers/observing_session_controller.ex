defmodule SolarObservationsWeb.ObservingSessionController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Event

  # ---------------------------------------------------------------------------
  # CRUD
  # ---------------------------------------------------------------------------

  def index(conn, _params) do
    render(conn, :index, sessions: Event.list_sessions())
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, session: Event.get_session!(id))
  end

  @doc """
  Создать сессию наблюдений (только запись в БД, без команд железу).
  Для запуска наводки и слежения используй POST /sessions/:id/start.

  POST /api/observing_sessions
  Body: {
    "observing_session": {
      "mount_id":   "uuid",
      "camera_id":  "uuid",   # опционально
      "notes":      "string"  # опционально
    }
  }
  """
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

  # ---------------------------------------------------------------------------
  # Жизненный цикл сессии
  # ---------------------------------------------------------------------------

  @doc """
  Запустить сессию: инициализировать монтировку, навести на Солнце,
  начать слежение и (опционально) запустить поток камеры.
  Логирует mount_command событие в сессию.

  POST /api/observing_sessions/:id/start
  Body (опционально): {
    "exposure_us": 1000000,
    "gain": 0
  }
  Response: {
    session,
    sun_position: {ra, dec, altitude, azimuth},
    tracking_started_at: datetime,
    camera_stream: bool
  }
  """
  def start(conn, %{"id" => id} = params) do
    session = Event.get_session!(id)
    camera_opts = Map.take(params, ["exposure_us", "gain"])

    with {:ok, result} <- Event.start_session(session, camera_opts) do
      render(conn, :started, result: result)
    end
  end

  @doc """
  Корректно завершить сессию: остановить слежение, поток камеры,
  вернуть монтировку в HOME. Фиксирует ended_at.

  POST /api/observing_sessions/:id/end
  Response: {session}
  """
  def end_session(conn, %{"id" => id}) do
    with {:ok, session} <- Event.end_session(Event.get_session!(id)) do
      render(conn, :show, session: session)
    end
  end

  @doc """
  Аварийное завершение сессии: мгновенная остановка всех осей,
  стоп камеры. Фиксирует статус :aborted.

  POST /api/observing_sessions/:id/abort
  Response: {session}
  """
  def abort(conn, %{"id" => id}) do
    with {:ok, session} <- Event.abort_session(Event.get_session!(id)) do
      render(conn, :show, session: session)
    end
  end

  # ---------------------------------------------------------------------------
  # Синхронизация и корректировка во время сессии
  # ---------------------------------------------------------------------------

  @doc """
  Синхронизация по Солнцу во время активной сессии.
  Логирует correction событие.

  POST /api/observing_sessions/:id/sync
  Response: {calibration: %{offset_ra, offset_dec, synced_at}}
  """
  def sync(conn, %{"id" => id}) do
    session = Event.get_session!(id)

    with {:ok, calibration} <- Event.sync_session(session) do
      render(conn, :sync, calibration: calibration)
    end
  end
end
