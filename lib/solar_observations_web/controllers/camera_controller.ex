defmodule SolarObservationsWeb.CameraController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Device

  # ---------------------------------------------------------------------------
  # CRUD — работа с записями в БД
  # ---------------------------------------------------------------------------

  def index(conn, _params) do
    render(conn, :index, cameras: Device.list_cameras())
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, camera: Device.get_camera!(id))
  end

  def create(conn, %{"camera" => params}) do
    with {:ok, camera} <- Device.create_camera(params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/cameras/#{camera}")
      |> render(:show, camera: camera)
    end
  end

  def update(conn, %{"id" => id, "camera" => params}) do
    with {:ok, camera} <- Device.update_camera(Device.get_camera!(id), params) do
      render(conn, :show, camera: camera)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Device.delete_camera(Device.get_camera!(id)) do
      send_resp(conn, :no_content, "")
    end
  end

  def by_mount(conn, %{"mount_id" => mount_id}) do
    render(conn, :index, cameras: Device.list_cameras_by_mount(mount_id))
  end

  # ---------------------------------------------------------------------------
  # Состояние камеры
  # ---------------------------------------------------------------------------

  @doc """
  Статус воркера камеры: camera_state, frames_sent, last_frame_at, roi.

  GET /api/cameras/:id/status
  Response: {
    camera_state: "idle" | "capturing" | "streaming" | "disconnected",
    frames_sent:  integer,
    last_frame_at: datetime | null,
    roi: {width, height, bin, img_type}
  }
  """
  def status(conn, %{"id" => id}) do
    camera = Device.get_camera!(id)

    with {:ok, worker_status} <- Device.get_camera_status(camera) do
      render(conn, :status, status: Map.put(worker_status, :camera, camera))
    end
  end

  @doc """
  Текущая температура сенсора (°C).

  GET /api/cameras/:id/temperature
  Response: {temperature_celsius: float}

  Пример: {"temperature_celsius": -10.3}
  """
  def temperature(conn, %{"id" => id}) do
    Device.get_camera!(id)

    with {:ok, celsius} <- Device.get_camera_temperature() do
      render(conn, :temperature, temperature_celsius: celsius)
    end
  end

  # ---------------------------------------------------------------------------
  # Одиночный снимок
  # ---------------------------------------------------------------------------

  @doc """
  Сделать одиночный снимок и вернуть метаданные.
  Сырой кадр сохраняется на диск, URL возвращается в ответе.

  POST /api/cameras/:id/capture
  Body: {
    "exposure_us": 1000000,   # выдержка в мкс, обязательно
    "gain":        0          # усиление, опционально (default: 0)
  }
  Response: {
    frame_url:    "/frames/2024-01-15T10:30:00Z.fits",
    width:        9576,
    height:       6388,
    format:       "raw16",
    exposure_us:  1000000,
    gain:         0,
    captured_at:  datetime
  }

  Таймаут запроса = exposure_us / 1000 + 10 000 мс.
  Ошибки: 409 если камера занята, 503 если не подключена.
  """
  def capture(conn, %{"id" => id, "exposure_us" => exposure_us} = params) do
    Device.get_camera!(id)
    gain = Map.get(params, "gain", 0)

    with {:ok, result} <- Device.capture_frame(exposure_us, gain) do
      render(conn, :capture, result: result)
    end
  end

  # ---------------------------------------------------------------------------
  # Потоковая съёмка
  # ---------------------------------------------------------------------------

  @doc """
  Запустить непрерывный поток кадров.
  Кадры рассылаются через Phoenix.PubSub → "camera:frames".
  Фронт подписывается по WebSocket/LiveView, не по HTTP.

  POST /api/cameras/:id/stream/start
  Body: {
    "exposure_us": 1000000,   # выдержка в мкс, обязательно
    "gain":        0          # усиление, опционально (default: 0)
  }
  Response: {message, pubsub_topic: "camera:frames"}

  Ошибки: 409 если поток уже запущен.
  """
  def start_stream(conn, %{"id" => id, "exposure_us" => exposure_us} = params) do
    Device.get_camera!(id)
    gain = Map.get(params, "gain", 0)

    with :ok <- Device.start_camera_stream(exposure_us: exposure_us, gain: gain) do
      render(conn, :stream_started,
        message: "Stream started",
        pubsub_topic: "camera:frames"
      )
    end
  end

  @doc """
  Остановить непрерывный поток.

  POST /api/cameras/:id/stream/stop
  Response: {message, frames_sent: integer}

  Ошибки: 409 если поток не запущен.
  """
  def stop_stream(conn, %{"id" => id}) do
    Device.get_camera!(id)

    with {:ok, result} <- Device.stop_camera_stream() do
      render(conn, :stream_stopped,
        message: "Stream stopped",
        frames_sent: result.frames_sent
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Управление охладителем
  # ---------------------------------------------------------------------------

  @doc """
  Установить целевую температуру охладителя и включить его.

  POST /api/cameras/:id/cooler
  Body: {"target_celsius": -10.0}
  Response: {message, target_celsius: float}

  Диапазон: обычно от -30°C до +20°C (зависит от модели камеры).
  Фактическая температура доступна через GET /cameras/:id/temperature.
  """
  def set_cooler(conn, %{"id" => id, "target_celsius" => target_celsius}) do
    Device.get_camera!(id)

    with :ok <- Device.set_camera_temperature(target_celsius) do
      render(conn, :cooler_set,
        message: "Cooler target set",
        target_celsius: target_celsius
      )
    end
  end

  @doc """
  Выключить охладитель (без изменения целевой температуры).

  DELETE /api/cameras/:id/cooler
  Response: {message}
  """
  def disable_cooler(conn, %{"id" => id}) do
    Device.get_camera!(id)

    with :ok <- Device.disable_camera_cooler() do
      render(conn, :cooler_disabled, message: "Cooler disabled")
    end
  end
end
