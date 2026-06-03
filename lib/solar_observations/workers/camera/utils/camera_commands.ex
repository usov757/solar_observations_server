defmodule SolarObservations.Workers.Camera.Utils.CameraCommands do
  @moduledoc """
  Сборка бинарных команд для отправки в asi_port через Port.command/2.

  Каждая публичная функция возвращает binary() — готовую к отправке
  команду. Никаких зависимостей от других модулей проекта.

  Опкоды обязаны совпадать с #define CMD_* в asi_port.c.
  """

  # -------------------------------------------------------------------------
  # Опкоды команд — совпадают с asi_port.c
  # -------------------------------------------------------------------------

  @cmd_open_camera    0x01
  @cmd_set_roi        0x02
  @cmd_set_control    0x03
  @cmd_start_exposure 0x04
  @cmd_get_exp_status 0x05
  @cmd_get_frame      0x06
  @cmd_close_camera   0x07
  @cmd_get_temp       0x08
  @cmd_set_cooler     0x09

  # -------------------------------------------------------------------------
  # ASI_CONTROL_TYPE из ASICamera2.h
  # -------------------------------------------------------------------------

  @asi_gain        0
  @asi_exposure    1
  @asi_cooler_on   17
  @asi_target_temp 16

  # -------------------------------------------------------------------------
  # ASI_IMG_TYPE из ASICamera2.h
  # -------------------------------------------------------------------------

  @asi_img_raw8   0
  @asi_img_rgb24  1
  @asi_img_raw16  2
  @asi_img_y8     3

  # -------------------------------------------------------------------------
  # ASI6200MM Pro — параметры сенсора по умолчанию
  # -------------------------------------------------------------------------

  @default_width  9576
  @default_height 6388
  @default_bin    1

  # Геттеры констант — нужны воркеру и CameraResponse
  def default_width,  do: @default_width
  def default_height, do: @default_height
  def default_bin,    do: @default_bin
  def asi_img_raw16,  do: @asi_img_raw16

  # -------------------------------------------------------------------------
  # Команды
  # -------------------------------------------------------------------------

  @doc "Открыть первую обнаруженную камеру."
  @spec open_camera() :: binary()
  def open_camera, do: <<@cmd_open_camera>>

  @doc "Закрыть камеру (asi_port сам выключит охладитель)."
  @spec close_camera() :: binary()
  def close_camera, do: <<@cmd_close_camera>>

  @doc """
  Установить формат ROI.
  По умолчанию — полное разрешение ASI6200MM Pro, RAW16, bin1.
  """
  @spec set_roi() :: binary()
  @spec set_roi(pos_integer(), pos_integer(), pos_integer(), non_neg_integer()) :: binary()
  def set_roi(
        width    \\ @default_width,
        height   \\ @default_height,
        bin      \\ @default_bin,
        img_type \\ @asi_img_raw16
      ) do
    <<@cmd_set_roi,
      width::32-big,
      height::32-big,
      bin::8,
      img_type::8>>
  end

  @doc "Установить выдержку в микросекундах."
  @spec set_exposure(pos_integer()) :: binary()
  def set_exposure(us) when is_integer(us) and us > 0,
    do: set_control(@asi_exposure, us)

  @doc "Установить усиление (0 = минимальное)."
  @spec set_gain(non_neg_integer()) :: binary()
  def set_gain(gain) when is_integer(gain) and gain >= 0,
    do: set_control(@asi_gain, gain)

  @doc "Включить охладитель с заданной целевой температурой (°C)."
  @spec set_cooler(number()) :: binary()
  def set_cooler(celsius) do
    tenths = round(celsius * 10)
    <<@cmd_set_cooler, tenths::32-big-signed>>
  end

  @doc "Включить / выключить охладитель без изменения целевой температуры."
  @spec set_cooler_on(boolean()) :: binary()
  def set_cooler_on(true),  do: set_control(@asi_cooler_on, 1)
  def set_cooler_on(false), do: set_control(@asi_cooler_on, 0)

  @doc "Начать одиночную экспозицию (snap mode, dark=false)."
  @spec start_exposure() :: binary()
  def start_exposure, do: <<@cmd_start_exposure>>

  @doc "Запросить статус текущей экспозиции."
  @spec get_exp_status() :: binary()
  def get_exp_status, do: <<@cmd_get_exp_status>>

  @doc "Забрать кадр после успешной экспозиции."
  @spec get_frame() :: binary()
  def get_frame, do: <<@cmd_get_frame>>

  @doc "Запросить температуру сенсора (ответ: int32 = °C × 10)."
  @spec get_temperature() :: binary()
  def get_temperature, do: <<@cmd_get_temp>>

  # -------------------------------------------------------------------------
  # Приватное
  # -------------------------------------------------------------------------

  @spec set_control(non_neg_integer(), integer()) :: binary()
  defp set_control(ctrl_type, value) do
    <<@cmd_set_control,
      ctrl_type::32-big,
      value::32-big-signed>>
  end
end
