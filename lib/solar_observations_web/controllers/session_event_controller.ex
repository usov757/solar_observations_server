defmodule SolarObservationsWeb.SessionEventController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Event

  # ---------------------------------------------------------------------------
  # CRUD
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Типизированные события — монтировка
  # ---------------------------------------------------------------------------

  @doc """
  Залогировать команду монтировки.

  POST /api/session_events/mount_command
  Body: {
    "session_id": "uuid",
    "mount_command": {
      "command":  "goto_sun",       # goto_sun | start_tracking | stop_tracking
                                    # | initialize | sync | goto | stop | sleep
      "axis":     "1",              # опционально, для осевых команд
      "params":   {}                # произвольные параметры команды
    }
  }
  """
  def create_mount_command(conn, %{"session_id" => session_id, "mount_command" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "mount_command", params) do
      render(conn, :show, event: event)
    end
  end

  @doc """
  Залогировать корректировку наводки (ручная или авто).

  POST /api/session_events/correction
  Body: {
    "session_id": "uuid",
    "correction": {
      "offset_ra_steps":  integer,
      "offset_dec_steps": integer,
      "method":           "manual" | "sync" | "auto",
      "notes":            "string"   # опционально
    }
  }
  """
  def create_correction(conn, %{"session_id" => session_id, "correction" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "correction", params) do
      render(conn, :show, event: event)
    end
  end

  @doc """
  Залогировать ошибку во время сессии.

  POST /api/session_events/error
  Body: {
    "session_id": "uuid",
    "error": {
      "source":  "mount" | "camera" | "system",
      "code":    "string",
      "message": "string",
      "fatal":   bool      # опционально, default: false
    }
  }
  """
  def create_error(conn, %{"session_id" => session_id, "error" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "error", params) do
      render(conn, :show, event: event)
    end
  end

  # ---------------------------------------------------------------------------
  # Типизированные события — камера
  # ---------------------------------------------------------------------------

  @doc """
  Залогировать команду камеры.

  POST /api/session_events/camera_command
  Body: {
    "session_id": "uuid",
    "camera_command": {
      "command":     "capture" | "start_stream" | "stop_stream"
                     | "set_cooler" | "disable_cooler",
      "exposure_us": integer,   # для capture и stream
      "gain":        integer,   # для capture и stream
      "params":      {}         # произвольные доп. параметры
    }
  }
  """
  def create_camera_command(conn, %{"session_id" => session_id, "camera_command" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "camera_command", params) do
      render(conn, :show, event: event)
    end
  end

  @doc """
  Залогировать метаданные захваченного кадра.

  POST /api/session_events/frame_captured
  Body: {
    "session_id": "uuid",
    "frame_captured": {
      "frame_url":   "/frames/...",
      "width":       9576,
      "height":      6388,
      "format":      "raw16",
      "exposure_us": 1000000,
      "gain":        0,
      "temperature_celsius": -10.3   # температура сенсора в момент съёмки
    }
  }
  """
  def create_frame_captured(conn, %{"session_id" => session_id, "frame_captured" => params}) do
    with {:ok, event} <- Event.create_typed_event(session_id, "frame_captured", params) do
      render(conn, :show, event: event)
    end
  end
end
