defmodule SolarObservations.Workers.Camera.Utils.CameraResponse do
  @moduledoc """
  Разбор бинарных ответов от asi_port.

  Протокол ответов (первый байт тела после 4-байтового заголовка длины):
    0x00 — успех, далее опциональные данные
    0xFF — ошибка, далее ASCII-строка с причиной

  Модуль предоставляет специализированные парсеры для каждого типа ответа,
  которые воркер вызывает в соответствующих handle_info-клозах.
  """

  # -------------------------------------------------------------------------
  # Типы
  # -------------------------------------------------------------------------

  @type exp_status :: :idle | :working | :success | :failed

  @type parse_result(t) :: {:ok, t} | {:error, binary()}

  # -------------------------------------------------------------------------
  # Парсеры
  # -------------------------------------------------------------------------

  @doc """
  Ответ на open_camera: `<<0x00, cam_id::8>>`.
  Возвращает `{:ok, cam_id}` или `{:error, reason}`.
  """
  @spec camera_opened(binary()) :: parse_result(0..255)
  def camera_opened(<<0x00, cam_id::8>>), do: {:ok, cam_id}
  def camera_opened(<<0xFF, reason::binary>>),    do: {:error, reason}
  def camera_opened(other),                       do: {:error, "unexpected: #{inspect(other)}"}

  @doc """
  Ответ на команды без возвращаемых данных:
  set_roi, set_exposure, set_gain, set_cooler, start_exposure, close_camera.

  Возвращает `:ok` или `{:error, reason}`.
  """
  @spec ack(binary()) :: :ok | {:error, binary()}
  def ack(<<0x00>>),                    do: :ok
  def ack(<<0xFF, reason::binary>>),    do: {:error, reason}
  def ack(other),                       do: {:error, "unexpected: #{inspect(other)}"}

  @doc """
  Ответ на get_exp_status: `<<0x00, status::8>>`.

  Значения status соответствуют ASI_EXPOSURE_STATUS:
    0 — idle     (камера свободна, можно начинать)
    1 — working  (экспозиция в процессе)
    2 — success  (кадр готов, вызывать get_frame)
    3 — failed   (ошибка, повторить экспозицию)
  """
  @spec exp_status(binary()) :: parse_result(exp_status())
  def exp_status(<<0x00, 0>>),               do: {:ok, :idle}
  def exp_status(<<0x00, 1>>),               do: {:ok, :working}
  def exp_status(<<0x00, 2>>),               do: {:ok, :success}
  def exp_status(<<0x00, 3>>),               do: {:ok, :failed}
  def exp_status(<<0xFF, reason::binary>>),  do: {:error, reason}
  def exp_status(other),                     do: {:error, "unexpected: #{inspect(other)}"}

  @doc """
  Ответ на get_frame: `<<0x00, frame::binary>>`.

  `frame` — сырые пиксельные данные в формате, заданном set_roi
  (для ASI6200MM Pro по умолчанию RAW16: width × height × 2 байт).
  """
  @spec frame(binary()) :: parse_result(binary())
  def frame(<<0x00, data::binary>>) when byte_size(data) > 0, do: {:ok, data}
  def frame(<<0xFF, reason::binary>>),                         do: {:error, reason}
  def frame(other),                                            do: {:error, "unexpected: #{inspect(other)}"}

  @doc """
  Ответ на get_temperature: `<<0x00, raw::32-big-signed>>`.

  ASI_TEMPERATURE хранится умноженным на 10. Возвращает `{:ok, float}` в °C.
  Например: raw=253 → 25.3°C, raw=-100 → -10.0°C.
  """
  @spec temperature(binary()) :: parse_result(float())
  def temperature(<<0x00, raw::32-big-signed>>),  do: {:ok, raw / 10.0}
  def temperature(<<0xFF, reason::binary>>),       do: {:error, reason}
  def temperature(other),                          do: {:error, "unexpected: #{inspect(other)}"}

  @doc """
  Универсальный парсер для случаев, когда тип ответа неизвестен заранее.

  Используется как fallback в handle_info. Возвращает:
    `:ok`              — команда выполнена без данных
    `{:ok, binary()}`  — ответ с телом (кадр или произвольные данные)
    `{:error, binary}` — ошибка
  """
  @spec parse(binary()) :: :ok | {:ok, binary()} | {:error, binary()}
  def parse(<<0x00>>),                           do: :ok
  def parse(<<0x00, _rest::binary>> = data),     do: {:ok, data}
  def parse(<<0xFF, reason::binary>>),           do: {:error, reason}
  def parse(other),                              do: {:error, "unexpected: #{inspect(other)}"}
end
