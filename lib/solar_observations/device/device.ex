defmodule SolarObservations.Device do
  @moduledoc """
  Контекст для работы с устройствами: монтировками и камерами.

  Единственная точка входа для контроллеров — как для DB операций,
  так и для управления физической монтировкой через MountWorker.
  """

  alias SolarObservations.{Camera, Mount, Repo}
  alias SolarObservations.Workers.MountWorker
  import Ecto.Query

  # --- Mount: DB ---

  def list_mounts, do: Repo.all(Mount)

  def get_mount!(id), do: Repo.get!(Mount, id)

  def create_mount(attrs) do
    %Mount{} |> Mount.changeset(attrs) |> Repo.insert()
  end

  def update_mount(%Mount{} = mount, attrs) do
    mount |> Mount.changeset(attrs) |> Repo.update()
  end

  def delete_mount(%Mount{} = mount), do: Repo.delete(mount)

  # --- Mount: управление железом ---

  def check_connection, do: MountWorker.check_connection()

  def goto_sun(%Mount{} = _mount), do: MountWorker.goto_sun()

  def start_tracking(%Mount{} = mount),
    do: MountWorker.start_solar_tracking(mount.cpr_ra, mount.timer_freq)

  def stop_tracking, do: MountWorker.stop_and_return_home()

  def sync_to_sun, do: MountWorker.sync_to_sun()

  def sun_position(%Mount{} = mount) do
    SolarObservations.Mount.Operations.get_sun_position_for_mount(mount)
  end

  def initialize_mount, do: MountWorker.initialize("3")

  def get_axis_statuses, do: MountWorker.get_all_statuses()

  def get_position do
    with {:ok, pos1} <- MountWorker.get_position("1"),
         {:ok, pos2} <- MountWorker.get_position("2") do
      {:ok, %{axis1: pos1, axis2: pos2}}
    end
  end

  def stop_mount, do: MountWorker.instant_stop("3")

  # --- Camera: DB ---

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
end
