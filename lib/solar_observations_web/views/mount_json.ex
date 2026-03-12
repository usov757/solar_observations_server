defmodule SolarObservationsWeb.MountJSON do
  @moduledoc """
  View-модуль для сериализации данных монтировки в JSON.
  """

  alias SolarObservations.Mount

  def index(%{mounts: mounts}), do: %{mounts: Enum.map(mounts, &mount/1)}
  def show(%{mount: mount}), do: mount(mount)

  def errors(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  def error(%{message: message, reason: reason}) do
    %{error: message, reason: inspect(reason)}
  end

  def status(%{status: status}) do
    %{
      connected: status.connected,
      version: status.version,
      axis1_status: status.axis1_status,
      axis2_status: status.axis2_status,
      axis1_position: status.axis1_position,
      axis2_position: status.axis2_position,
      timestamp: status.timestamp,
      mount: mount(status.mount)
    }
  end

  def goto_sun(%{result: result}), do: %{message: "Sun pointing started", result: result}
  def tracking_started(%{result: result}), do: %{message: "Solar tracking started", result: result}
  def tracking_stopped(%{message: message}), do: %{message: message}
  def sync(%{calibration: calibration}), do: %{message: "Mount synchronized with Sun", calibration: calibration}
  def sun_position(%{sun_position: sun_position}), do: sun_position
  def initialized(%{message: message}), do: %{message: message}
  def axis_status(%{statuses: statuses}), do: statuses
  def position(%{axis1: axis1, axis2: axis2}), do: %{axis1: axis1, axis2: axis2}
  def stopped(%{message: message}), do: %{message: message}

  # --- Приватные функции ---

  defp mount(%Mount{} = mount) do
    %{
      id: mount.id,
      name: mount.name,
      port: mount.port,
      connection_type: mount.connection_type,
      cpr_ra: mount.cpr_ra,
      timer_freq: mount.timer_freq,
      tracking_period: mount.tracking_period,
      latitude: decimal_or_nil(mount.latitude),
      longitude: decimal_or_nil(mount.longitude),
      baud_rate: mount.baud_rate,
      reconnect_interval: mount.reconnect_interval,
      initialized: mount.initialized,
      inserted_at: mount.inserted_at,
      updated_at: mount.updated_at
    }
  end

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(value), do: Decimal.to_float(value)

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
