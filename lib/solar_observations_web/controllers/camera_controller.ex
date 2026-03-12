defmodule SolarObservationsWeb.CameraController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Device

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
end
