defmodule SolarObservationsWeb.Router do
  use SolarObservationsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SolarObservationsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SolarObservationsWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", SolarObservationsWeb do
    pipe_through :api

    # -------------------------------------------------------------------------
    # Mounts
    # -------------------------------------------------------------------------
    resources "/mounts", MountController, except: [:new, :edit] do
      # Статус и диагностика
      get  "/status",       MountController, :status
      get  "/sun_position", MountController, :sun_position
      get  "/axis_status",  MountController, :axis_status
      get  "/position",     MountController, :position

      # Новый: читает cpr, timer_freq, firmware с контроллера
      get  "/params",       MountController, :params

      # Управление движением
      post "/initialize",    MountController, :initialize
      post "/goto_sun",      MountController, :goto_sun
      post "/start_tracking", MountController, :start_tracking
      post "/stop_tracking", MountController, :stop_tracking
      post "/stop",          MountController, :stop
      post "/sync",          MountController, :sync

      # Новые: тонкое управление
      post "/goto",          MountController, :goto         # поворот на градусы
      post "/sleep",         MountController, :sleep        # усыпить/разбудить ось
      post "/motion_mode",   MountController, :motion_mode  # режим движения
      post "/step_period",   MountController, :step_period  # период шага
      post "/start_motion",  MountController, :start_motion # запуск движения

      # Вложенные ресурсы (read-only shortcuts, полный CRUD по /cameras, /observing_sessions)
      get  "/cameras",             CameraController, :by_mount
      get  "/observing_sessions",  ObservingSessionController, :by_mount
    end

    # -------------------------------------------------------------------------
    # Cameras
    # -------------------------------------------------------------------------
    resources "/cameras", CameraController, except: [:new, :edit] do
      # Статус и телеметрия (проксируют CameraWorker)
      get    "/status",       CameraController, :status
      get    "/temperature",  CameraController, :temperature

      # Съёмка
      post   "/capture",      CameraController, :capture      # одиночный кадр → FITS на диск

      # Стриминг
      post   "/stream/start", CameraController, :stream_start
      post   "/stream/stop",  CameraController, :stream_stop

      # Охладитель (Пельтье)
      post   "/cooler",       CameraController, :cooler_on    # включить / задать температуру
      delete "/cooler",       CameraController, :cooler_off   # отключить
    end

    # -------------------------------------------------------------------------
    # Captures (статические FITS-файлы, сохранённые на диске)
    # GET /api/captures/:filename — отдаёт файл из priv/captures/
    # -------------------------------------------------------------------------
    get "/captures/:filename", CaptureController, :show

    # -------------------------------------------------------------------------
    # Observing Sessions
    # -------------------------------------------------------------------------
    resources "/observing_sessions", ObservingSessionController, except: [:new, :edit] do
      # Жизненный цикл
      post "/end",   ObservingSessionController, :end_session
      post "/abort", ObservingSessionController, :abort

      # Новые: оркестрация железа
      post "/start", ObservingSessionController, :start   # initialize → goto_sun → tracking → stream
      post "/sync",  ObservingSessionController, :sync    # синк с позицией Солнца

      # События сессии
      get  "/session_events", SessionEventController, :by_session
    end

    # -------------------------------------------------------------------------
    # Session Events
    # -------------------------------------------------------------------------
    resources "/session_events", SessionEventController, except: [:new, :edit]
  end

  # ---------------------------------------------------------------------------
  # Dev tools
  # ---------------------------------------------------------------------------
  if Application.compile_env(:solar_observations, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SolarObservationsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
