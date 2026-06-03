defmodule SolarObservationsWeb.MountController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Device

  # ---------------------------------------------------------------------------
  # CRUD — работа с записями в БД
  # ---------------------------------------------------------------------------

  def index(conn, _params) do
    render(conn, :index, mounts: Device.list_mounts())
  end

  def show(conn, %{"mount_id" => mount_id}) do
    render(conn, :show, mount: Device.get_mount!(mount_id))
  end

  def create(conn, %{"mount" => params}) do
    with {:ok, mount} <- Device.create_mount(params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/mounts/#{mount}")
      |> render(:show, mount: mount)
    end
  end

  def update(conn, %{"mount_id" => mount_id, "mount" => params}) do
    with {:ok, mount} <- Device.update_mount(Device.get_mount!(mount_id), params) do
      render(conn, :show, mount: mount)
    end
  end

  def delete(conn, %{"mount_id" => mount_id}) do
    with {:ok, _} <- Device.delete_mount(Device.get_mount!(mount_id)) do
      send_resp(conn, :no_content, "")
    end
  end

  # ---------------------------------------------------------------------------
  # Диагностика и состояние
  # ---------------------------------------------------------------------------

  @doc """
  Полная диагностика подключения.
  Включает версию прошивки, статусы осей, текущие позиции.

  GET /api/mounts/:mount_id/status
  Response: {connected, version, axes: %{ra: status, dec: status}, positions: %{ra, dec}}
  """
  def status(conn, %{"mount_id" => mount_id}) do
    mount = Device.get_mount!(mount_id)

    with {:ok, status} <- Device.check_connection() do
      render(conn, :status, status: Map.put(status, :mount, mount))
    end
  end

  @doc """
  Статус каждой оси: running, tracking_mode, direction, initialized.
  Включает is_moving — сравнивает позицию дважды с интервалом.

  GET /api/mounts/:mount_id/axis_status
  Response: {ra: %{running, tracking_mode, direction_ccw, initialized, is_moving}, dec: ...}
  """
  def axis_status(conn, %{"mount_id" => mount_id}) do
    Device.get_mount!(mount_id)

    with {:ok, statuses} <- Device.get_axis_statuses() do
      render(conn, :axis_status, statuses: statuses)
    end
  end

  @doc """
  Текущие позиции осей в шагах от HOME (0).

  GET /api/mounts/:mount_id/position
  Response: {axis1: integer, axis2: integer}
  """
  def position(conn, %{"mount_id" => mount_id}) do
    Device.get_mount!(mount_id)

    with {:ok, position} <- Device.get_position() do
      render(conn, :position, axis1: position.axis1, axis2: position.axis2)
    end
  end

  @doc """
  Текущее положение Солнца (RA, Dec, Alt, Az).

  GET /api/mounts/:mount_id/sun_position
  Response: {ra, dec, altitude, azimuth, timestamp}
  """
  def sun_position(conn, %{"mount_id" => mount_id}) do
    case Device.get_sun_position_for_mount(mount_id) do
      {:ok, sun} ->
        render(conn, :sun_position, sun_position: sun)

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Технические параметры контроллера монтировки.
  Нужны фронту для расчёта T1 и отображения характеристик.

  GET /api/mounts/:mount_id/params
  Response: {
    cpr_ra, cpr_dec,          # шагов на полный оборот каждой оси
    timer_freq,                # частота таймера (Гц)
    high_speed_ratio_ra,       # соотношение высокой/низкой скоростей
    high_speed_ratio_dec,
    firmware_version_ra,       # версия прошивки оси
    firmware_version_dec
  }
  """
  def params(conn, %{"mount_id" => mount_id}) do
    Device.get_mount!(mount_id)

    with {:ok, controller_params} <- Device.get_controller_params() do
      render(conn, :params, params: controller_params)
    end
  end

  # ---------------------------------------------------------------------------
  # Инициализация и режим сна
  # ---------------------------------------------------------------------------

  @doc """
  Инициализация осей (команда :F3).

  POST /api/mounts/:mount_id/initialize
  Body (опционально): {"axis": "1"} — конкретная ось; без тела — обе оси
  Response: {message}
  """
  def initialize(conn, %{"mount_id" => mount_id} = params) do
    Device.get_mount!(mount_id)
    axis = Map.get(params, "axis")

    with :ok <- Device.initialize_mount(axis) do
      render(conn, :initialized, message: "Mount initialized")
    end
  end

  @doc """
  Перевести ось в режим сна или вывести из него.

  POST /api/mounts/:mount_id/sleep
  Body: {"axis": "1", "enabled": true}
  Response: {message}
  """
  def sleep(conn, %{"mount_id" => mount_id, "axis" => axis, "enabled" => enabled}) do
    Device.get_mount!(mount_id)

    with :ok <- Device.set_axis_sleep(axis, enabled) do
      state = if enabled, do: "asleep", else: "awake"
      render(conn, :sleep, message: "Axis #{axis} is now #{state}")
    end
  end

  # ---------------------------------------------------------------------------
  # Движение и остановка
  # ---------------------------------------------------------------------------

  @doc """
  Мгновенная остановка одной или обеих осей.

  POST /api/mounts/:mount_id/stop
  Body (опционально): {"axis": "1"} — конкретная ось; без тела — обе ("3")
  Response: {message}
  """
  def stop(conn, %{"mount_id" => mount_id} = params) do
    Device.get_mount!(mount_id)
    axis = Map.get(params, "axis", "3")

    with :ok <- Device.stop_mount(axis) do
      render(conn, :stopped, message: "Mount stopped")
    end
  end

  @doc """
  Поворот оси на заданное количество градусов от текущей позиции.
  + CW, - CCW. Блокирует до завершения GOTO.

  POST /api/mounts/:mount_id/goto
  Body: {"axis": "1", "degrees": 5.0}
  Response: {axis, degrees, steps, final_position}

  Примеры:
    {"axis": "1", "degrees": 360.0}   — RA полный оборот CW
    {"axis": "2", "degrees": -10.0}   — Dec 10° CCW
  """
  def goto(conn, %{"mount_id" => mount_id, "axis" => axis, "degrees" => degrees}) do
    Device.get_mount!(mount_id)

    with {:ok, result} <- Device.goto_degrees(axis, degrees) do
      render(conn, :goto, result: result)
    end
  end

  @doc """
  Ручная установка режима движения оси.
  Нужен для тестирования и точной настройки без использования goto_sun.

  POST /api/mounts/:mount_id/motion_mode
  Body: {
    "axis":         "1",    # "1" = RA, "2" = Dec
    "mode":         0,      # 0 = GOTO, 1 = Tracking
    "direction":    0       # 0 = CW, 1 = CCW
  }
  Response: {message}
  """
  def motion_mode(conn, %{"mount_id" => mount_id, "axis" => axis, "mode" => mode, "direction" => direction}) do
    Device.get_mount!(mount_id)

    with :ok <- Device.set_motion_mode(axis, mode, direction) do
      render(conn, :motion_mode, message: "Motion mode set for axis #{axis}")
    end
  end

  @doc """
  Установить период шагов (T1) для режима слежения.

  POST /api/mounts/:mount_id/step_period
  Body: {"axis": "1", "t1_preset": 592}
  Response: {message}
  """
  def step_period(conn, %{"mount_id" => mount_id, "axis" => axis, "t1_preset" => t1_preset}) do
    Device.get_mount!(mount_id)

    with :ok <- Device.set_step_period(axis, t1_preset) do
      render(conn, :step_period, message: "Step period set for axis #{axis}")
    end
  end

  @doc """
  Запустить движение оси (после set_motion_mode + set_step_period).

  POST /api/mounts/:mount_id/start_motion
  Body: {"axis": "1"}
  Response: {message}
  """
  def start_motion(conn, %{"mount_id" => mount_id, "axis" => axis}) do
    Device.get_mount!(mount_id)

    with :ok <- Device.start_motion(axis) do
      render(conn, :motion_started, message: "Motion started for axis #{axis}")
    end
  end

  # ---------------------------------------------------------------------------
  # Солнечное слежение
  # ---------------------------------------------------------------------------

  @doc """
  Навести на Солнце и сразу запустить слежение (полный цикл).

  POST /api/mounts/:mount_id/goto_sun
  Response: {ra, dec, altitude, azimuth, tracking_started_at}
  """
  def goto_sun(conn, %{"mount_id" => mount_id}) do
    with {:ok, result} <- Device.goto_sun(Device.get_mount!(mount_id)) do
      render(conn, :goto_sun, result: result)
    end
  end

  @doc """
  Запустить слежение за Солнцем (труба уже направлена вручную).
  Опционально принимает CPR и timer_freq если не нужно читать с контроллера.

  POST /api/mounts/:mount_id/start_tracking
  Body (опционально): {"cpr": 9024000, "timer_freq": 64935800}
  Response: {t1_preset, tracking_rate_deg_per_sec, message}
  """
  def start_tracking(conn, %{"mount_id" => mount_id} = params) do
    mount = Device.get_mount!(mount_id)
    opts  = Map.take(params, ["cpr", "timer_freq"])

    with {:ok, result} <- Device.start_tracking(mount, opts) do
      render(conn, :tracking_started, result: result)
    end
  end

  @doc """
  Остановить слежение и вернуться в HOME (0, 0).

  POST /api/mounts/:mount_id/stop_tracking
  Response: {message}
  """
  def stop_tracking(conn, %{"mount_id" => mount_id}) do
    Device.get_mount!(mount_id)

    with :ok <- Device.stop_tracking() do
      render(conn, :tracking_stopped, message: "Tracking stopped and mount returned to HOME")
    end
  end

  @doc """
  Синхронизация: запомнить текущее положение трубы как позицию Солнца.
  Вызывается после ручной корректировки наводки.

  POST /api/mounts/:mount_id/sync
  Response: {calibration: %{offset_ra, offset_dec, synced_at}}
  """
  def sync(conn, %{"mount_id" => mount_id}) do
    Device.get_mount!(mount_id)

    with {:ok, calibration} <- Device.sync_to_sun() do
      render(conn, :sync, calibration: calibration)
    end
  end
end
