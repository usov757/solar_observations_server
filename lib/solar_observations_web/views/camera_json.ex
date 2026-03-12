defmodule SolarObservationsWeb.CameraJSON do
  @moduledoc """
  View-модуль для сериализации данных камер в JSON.

  Используется контроллером `SolarObservationsWeb.CameraController`
  для формирования ответов API.
  """

  alias SolarObservations.Camera

  @doc """
  Рендерит список камер.

  ## Пример ответа:
      {
        "cameras": [
          { "id": 1, "name": "ZWO ASI174MM", ... },
          ...
        ]
      }
  """
  def index(%{cameras: cameras}) do
    %{cameras: Enum.map(cameras, &camera/1)}
  end

  @doc """
  Рендерит одну камеру.
  """
  def show(%{camera: camera}) do
    camera(camera)
  end

  @doc """
  Рендерит ошибки валидации из changeset.

  ## Пример ответа:
      {
        "errors": {
          "name": ["can't be blank"],
          "focal_length_mm": ["must be greater than 0"]
        }
      }
  """
  def errors(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  # --- Приватные функции ---

  defp camera(%Camera{} = camera) do
    %{
      id: camera.id,
      name: camera.name,
      device_id: camera.device_id,
      focal_length_mm: decimal_or_nil(camera.focal_length_mm),
      default_exposure: decimal_or_nil(camera.default_exposure),
      default_gain: camera.default_gain,
      mount_id: camera.mount_id,
      mount: mount_summary(camera.mount),
      inserted_at: camera.inserted_at,
      updated_at: camera.updated_at
    }
  end

  defp mount_summary(nil), do: nil

  defp mount_summary(mount) do
    %{
      id: mount.id,
      name: mount.name
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
