defmodule SolarObservations.Device do
  @moduledoc """
  Контекст для работы с устройствами: монтировками и камерами.

  Единственная точка входа для контроллеров — как для DB операций,
  так и для управления физической монтировкой через MountWorker/CameraWorker.
  """

  alias SolarObservations.{Camera, Mount, Repo}
  alias SolarObservations.Workers.Camera.CameraWorker
  alias SolarObservations.Workers.Mount.MountWorker
  import Ecto.Query

  # ---------------------------------------------------------------------------
  # Mount: DB
  # ---------------------------------------------------------------------------

  def list_mounts, do: Repo.all(Mount)

  def get_mount!(id), do: Repo.get!(Mount, id)

  @spec create_mount(
          :invalid
          | %{optional(:__struct__) => none(), optional(atom() | binary()) => any()}
        ) :: any()
  def create_mount(attrs) do
    %Mount{} |> Mount.changeset(attrs) |> Repo.insert()
  end

  def update_mount(%Mount{} = mount, attrs) do
    mount |> Mount.changeset(attrs) |> Repo.update()
  end

  def delete_mount(%Mount{} = mount), do: Repo.delete(mount)

  # ---------------------------------------------------------------------------
  # Mount: управление железом (старые функции)
  # ---------------------------------------------------------------------------

  def check_connection, do: MountWorker.check_connection()

  def goto_sun(%Mount{} = _mount), do: MountWorker.goto_sun()

  def start_tracking(%Mount{} = mount),
    do: MountWorker.start_solar_tracking(mount.cpr_ra, mount.timer_freq)

  def start_tracking_with_params(cpr, timer_freq),
    do: MountWorker.start_solar_tracking(cpr, timer_freq)

  def stop_tracking, do: MountWorker.stop_and_return_home()

  def sync_to_sun, do: MountWorker.sync_to_sun()

  def sun_position(%Mount{} = mount) do
    SolarObservations.Mount.Operations.get_sun_position_for_mount(mount)
  end

  def initialize_mount(axis \\ "3"), do: MountWorker.initialize(axis)

  def get_axis_statuses, do: MountWorker.get_all_statuses()

  def get_position do
    with {:ok, pos1} <- MountWorker.get_position("1"),
         {:ok, pos2} <- MountWorker.get_position("2") do
      {:ok, %{axis1: pos1, axis2: pos2}}
    end
  end

  def stop_mount(axis \\ "3"), do: MountWorker.instant_stop(axis)

  # ---------------------------------------------------------------------------
  # Mount: управление железом (новые функции)
  # ---------------------------------------------------------------------------

  @doc """
  Читает с контроллера CPR, timer_freq и версию прошивки.
  Возвращает {:ok, %{cpr: _, timer_freq: _, firmware: _}} | {:error, reason}
  """
  def get_controller_params, do: MountWorker.get_controller_params()

  @doc """
  Усыпляет/будит указанную ось.
  axis: "1" | "2" | "3" (оба)
  sleep: true | false
  """
  def set_axis_sleep(axis, sleep) when axis in ["1", "2", "3"] and is_boolean(sleep) do
    MountWorker.set_axis_sleep(axis, sleep)
  end

  @doc """
  Поворот оси на указанное количество градусов (относительно текущей позиции).
  axis: "1" | "2"
  degrees: float
  """
  def goto_degrees(axis, degrees) when axis in ["1", "2"] and is_number(degrees) do
    MountWorker.goto_degrees(axis, degrees)
  end

  @doc """
  Устанавливает режим движения.
  axis: "1" | "2" | "3"
  mode: :tracking | :slewing | :guiding (атом или строка)
  direction: :positive | :negative (опционально, для slewing)
  """
  def set_motion_mode(axis, mode, direction \\ :positive) do
    MountWorker.set_motion_mode(axis, mode, direction)
  end

  @doc """
  Запускает движение по оси с текущими параметрами режима.
  axis: "1" | "2" | "3"
  """
  def start_motion(axis) when axis in ["1", "2", "3"] do
    MountWorker.start_motion(axis)
  end

  # ---------------------------------------------------------------------------
  # Camera: DB
  # ---------------------------------------------------------------------------

  def list_cameras do
    Repo.all(Camera) |> Repo.preload(:mount)
  end

  def list_cameras_by_mount(mount_id) do
    get_mount!(mount_id)
    Repo.all(from c in Camera, where: c.mount_id == ^mount_id, preload: :mount)
  end

  def get_camera!(id), do: Repo.get!(Camera, id) |> Repo.preload(:mount)

  def create_camera(attrs) do
    with {:ok, camera} <- %Camera{} |> Camera.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(camera, :mount)}
    end
  end

  def update_camera(%Camera{} = camera, attrs) do
    with {:ok, camera} <- camera |> Camera.changeset(attrs) |> Repo.update() do
      {:ok, Repo.preload(camera, :mount)}
    end
  end

  def delete_camera(%Camera{} = camera), do: Repo.delete(camera)

  # ---------------------------------------------------------------------------
  # Camera: управление железом (новые функции)
  # ---------------------------------------------------------------------------

  @doc """
  Возвращает текущий статус камеры: подключена, охлаждение, режим съёмки и т.д.
  camera_id используется для маршрутизации если воркеров несколько.
  Возвращает {:ok, %{connected:, cooling:, temperature:, streaming:, ...}} | {:error, reason}
  """
  def get_camera_status(camera_id) do
    CameraWorker.get_status(camera_id)
  end

  @doc """
  Делает одиночный снимок с указанной экспозицией.
  Сохраняет FITS файл на диск в priv/captures/<session_id>/.
  Возвращает {:ok, %{url:, filename:, size:, captured_at:}} | {:error, reason}
  """
  def capture_frame(camera_id, exposure_ms) when is_integer(exposure_ms) and exposure_ms > 0 do
    CameraWorker.capture(camera_id, exposure_ms)
  end

  @doc """
  Запускает непрерывный стриминг кадров с камеры.
  """
  def start_camera_stream(camera_id) do
    CameraWorker.start_stream(camera_id)
  end

  @doc """
  Останавливает стриминг кадров.
  """
  def stop_camera_stream do
    CameraWorker.stop_stream()
  end

  @doc """
  Устанавливает целевую температуру сенсора камеры (для охлаждения Пельтье).
  target_celsius: float, например -10.0
  """
  def set_camera_temperature(target_celsius) when is_number(target_celsius) do
    CameraWorker.set_cooler_temperature(target_celsius)
  end

  @doc """
  Отключает охладитель камеры.
  """
  def disable_camera_cooler do
    CameraWorker.disable_cooler()
  end


   @doc """
  Возвращает активную монтировку (первую с active = true).
  """
  def get_active_mount do
    Repo.get_by(Mount, active: true)
  end

  @doc """
  Возвращает позицию Солнца для активной монтировки.
  Если активной монтировки нет, возвращает {:error, :no_active_mount}.
  """
  def get_sun_position do
    case get_active_mount() do
      nil -> {:error, :no_active_mount}
      _ -> MountWorker.get_sun_position()
    end
  end

  @doc """
  Возвращает позицию Солнца для конкретной монтировки по id.
  Проверяет, что монтировка существует и активна.
  """
  def get_sun_position_for_mount(mount_id) do
    mount = Repo.get(Mount, mount_id)
    if mount && mount.active do
      MountWorker.get_sun_position()
    else
      {:error, :mount_not_found_or_inactive}
    end
  end

end
