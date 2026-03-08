
defmodule SolarObservations.Astronomy.MountCoordinates do
  @moduledoc """
  Преобразование небесных координат в позиции моторов ЭКВАТОРИАЛЬНОЙ монтировки.

  ОБНОВЛЕНИЕ: Добавлены правильные расчеты для скорости слежения
  """
  require Logger

  alias SolarObservations.Workers.MountWorker

  def initialize_mount_params do
    with {:ok, axis1_cpr} <- MountWorker.get_cpr("1"),
         {:ok, axis2_cpr} <- MountWorker.get_cpr("2"),
         {:ok, timer_freq} <- MountWorker.get_timer_freq("1"),
         {:ok, high_speed_ratio} <- MountWorker.get_high_speed_ratio("1") do

      Logger.info("""
      Mount Parameters:
        Axis1 (RA) CPR: #{axis1_cpr}
        Axis2 (Dec) CPR: #{axis2_cpr}
        Timer Frequency: #{timer_freq} Hz
        High Speed Ratio (N): #{high_speed_ratio}
      """)

      params = %{
        axis1_cpr: axis1_cpr,
        axis2_cpr: axis2_cpr,
        timer_freq: timer_freq,
        high_speed_ratio: high_speed_ratio
      }

      {:ok, params}
    end
  end

  @doc """
  Преобразует RA/Dec в шаги монтировки.
  """
  def radec_to_steps(ra, dec, mount_params, tube_offset \\ 90.0) do
    # Ось 1 (RA): 24 часа RA = 360° = полный оборот оси
    axis1_degrees = ra / 24.0 * 360.0
    axis1_steps = round(axis1_degrees / 360.0 * mount_params.axis1_cpr)

    # Ось 2 (Dec): Dec + tube_offset
    axis2_degrees = dec + tube_offset
    axis2_steps = round(axis2_degrees / 360.0 * mount_params.axis2_cpr)

    {:ok, %{
      axis1_steps: axis1_steps,
      axis2_steps: axis2_steps,
      axis1_degrees: axis1_degrees,
      axis2_degrees: axis2_degrees
    }}
  end

  @doc """
  УСТАРЕЛО: Используйте SolarTracker.calculate_t1_preset/4 вместо этой функции.
  """
  def calculate_tracking_speed(speed_deg_per_sec, axis_cpr, timer_freq) do
    # Устаревшая функция, теперь используем правильную из SolarTracker
    SolarObservations.Astronomy.SolarTracker.calculate_t1_preset(
      speed_deg_per_sec,
      axis_cpr,
      timer_freq,
      1  # Без high-speed режима по умолчанию
    )
  end

  @doc """
  Получает текущую позицию монтировки в градусах.
  """
  def get_current_position_degrees(mount_params) do
    with {:ok, axis1_pos} <- MountWorker.get_position("1"),
         {:ok, axis2_pos} <- MountWorker.get_position("2") do

      # Ось 1: шаги -> градусы -> часы RA
      axis1_deg = axis1_pos / mount_params.axis1_cpr * 360.0
      axis1_ra = axis1_deg / 15.0  # Переводим в часы

      # Ось 2: шаги -> градусы -> Dec (вычитаем tube_offset)
      axis2_deg = axis2_pos / mount_params.axis2_cpr * 360.0
      axis2_dec = axis2_deg - 90.0  # Стандартный offset 90°

      {:ok, %{
        axis1_degrees: axis1_deg,
        axis1_ra: axis1_ra,
        axis2_degrees: axis2_deg,
        axis2_dec: axis2_dec
      }}
    end
  end
end
