defmodule SolarObservationsWeb.MountController do
  use SolarObservationsWeb, :controller

  alias SolarObservations.Device

  def index(conn, _params) do
    render(conn, :index, mounts: Device.list_mounts())
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, mount: Device.get_mount!(id))
  end

  def create(conn, %{"mount" => params}) do
    with {:ok, mount} <- Device.create_mount(params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/mounts/#{mount}")
      |> render(:show, mount: mount)
    end
  end

  def update(conn, %{"id" => id, "mount" => params}) do
    with {:ok, mount} <- Device.update_mount(Device.get_mount!(id), params) do
      render(conn, :show, mount: mount)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Device.delete_mount(Device.get_mount!(id)) do
      send_resp(conn, :no_content, "")
    end
  end

  def status(conn, %{"id" => id}) do
    mount = Device.get_mount!(id)

    with {:ok, status} <- Device.check_connection() do
      render(conn, :status, status: Map.put(status, :mount, mount))
    end
  end

  def goto_sun(conn, %{"id" => id}) do
    with {:ok, result} <- Device.goto_sun(Device.get_mount!(id)) do
      render(conn, :goto_sun, result: result)
    end
  end

  def start_tracking(conn, %{"id" => id}) do
    with {:ok, result} <- Device.start_tracking(Device.get_mount!(id)) do
      render(conn, :tracking_started, result: result)
    end
  end

  def stop_tracking(conn, %{"id" => id}) do
    Device.get_mount!(id)

    with :ok <- Device.stop_tracking() do
      render(conn, :tracking_stopped, message: "Tracking stopped and mount returned to HOME")
    end
  end

  def sync(conn, %{"id" => id}) do
    Device.get_mount!(id)

    with {:ok, calibration} <- Device.sync_to_sun() do
      render(conn, :sync, calibration: calibration)
    end
  end

  def sun_position(conn, %{"id" => id}) do
    with {:ok, sun_position} <- Device.sun_position(Device.get_mount!(id)) do
      render(conn, :sun_position, sun_position: sun_position)
    end
  end

  def initialize(conn, %{"id" => id}) do
    Device.get_mount!(id)

    with :ok <- Device.initialize_mount() do
      render(conn, :initialized, message: "Mount initialized")
    end
  end

  def axis_status(conn, %{"id" => id}) do
    Device.get_mount!(id)

    with {:ok, statuses} <- Device.get_axis_statuses() do
      render(conn, :axis_status, statuses: statuses)
    end
  end

  def position(conn, %{"id" => id}) do
    Device.get_mount!(id)

    with {:ok, position} <- Device.get_position() do
      render(conn, :position, axis1: position.axis1, axis2: position.axis2)
    end
  end

  def stop(conn, %{"id" => id}) do
    Device.get_mount!(id)

    with :ok <- Device.stop_mount() do
      render(conn, :stopped, message: "Mount stopped")
    end
  end
end
