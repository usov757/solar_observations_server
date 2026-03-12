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

  # Other scopes may use custom stacks.
  scope "/api", SolarObservationsWeb do
    pipe_through :api

    # Mounts
    resources "/mounts", MountController, except: [:new, :edit] do
      get "/status", MountController, :status
      post "/goto_sun", MountController, :goto_sun
      post "/start_tracking", MountController, :start_tracking
      post "/stop_tracking", MountController, :stop_tracking
      post "/sync", MountController, :sync
      get "/sun_position", MountController, :sun_position
      post "/initialize", MountController, :initialize
      get "/axis_status", MountController, :axis_status
      get "/position", MountController, :position
      post "/stop", MountController, :stop
      get "/cameras", CameraController, :by_mount
      get "/observing_sessions", ObservingSessionController, :by_mount
    end

    # Cameras
    resources "/cameras", CameraController, except: [:new, :edit]

    # Observing sessions
    resources "/observing_sessions", ObservingSessionController, except: [:new, :edit] do
      post "/end", ObservingSessionController, :end_session
      post "/abort", ObservingSessionController, :abort
      get "/session_events", SessionEventController, :by_session
    end

    # Session events
    resources "/session_events", SessionEventController, except: [:new, :edit]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:solar_observations, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SolarObservationsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
