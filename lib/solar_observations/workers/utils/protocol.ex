defmodule SolarObservations.Workers.Utils.Protocol do
  @moduledoc """
  Кодирование и декодирование протокола SkyWatcher Motor Controller.

  Протокол:
    Команды: ":" + cmd_char + channel("1"/"2"/"3") + data + CR
    Ответы:  "=" + data + CR (успех) | "!" + error_code + CR (ошибка)
    Данные:  24-bit little-endian hex, e.g. 0x123456 → "563412"
    Позиция: с offset 0x800000 (send: pos+0x800000, receive: raw-0x800000)
  """

  import Bitwise

  @position_offset 0x800000

  # ===========================================================================
  # Кодирование
  # ===========================================================================

  @doc """
  Кодирует позицию в шагах в 6-символьный little-endian hex для команды :S.

    1 шаг  → raw=0x800001 → "010080"
    -1 шаг → raw=0x7FFFFF → "FFFF7F"
  """
  def encode_position(steps) when is_integer(steps),
    do: encode_24bit(steps + @position_offset)

  @doc """
  Кодирует 24-bit значение в little-endian hex строку.

    0x123456 → "563412"
  """
  def encode_24bit(value) when is_integer(value) and value >= 0 do
    data   = value &&& 0xFFFFFF
    byte_a = (data >>> 16) &&& 0xFF
    byte_b = (data >>>  8) &&& 0xFF
    byte_c =  data         &&& 0xFF
    byte_to_hex(byte_c) <> byte_to_hex(byte_b) <> byte_to_hex(byte_a)
  end

  # ===========================================================================
  # Разбор буфера
  # ===========================================================================

  @doc """
  Извлекает полный ответ из буфера (разделитель CR).

  Возвращает `{:complete, response, rest}` или `{:incomplete, buffer}`.
  """
  def parse_complete(buffer) do
    clean = String.replace(buffer, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    case String.split(clean, "\r", parts: 2) do
      [response, rest] -> {:complete, String.trim(response), rest}
      [incomplete]     -> {:incomplete, incomplete}
    end
  end

  @doc """
  Разбирает ответ контроллера.

    "=data" → `{:ok, "data"}`
    "!code" → `{:error, atom}`
  """
  def parse_response(response) do
    clean = String.trim(response)
    cond do
      String.starts_with?(clean, "=") -> {:ok, String.slice(clean, 1..-1//1)}
      String.starts_with?(clean, "!") -> {:error, parse_error_code(String.slice(clean, 1..-1//1))}
      clean == ""                     -> {:ok, ""}
      String.match?(clean, ~r/^[0-9A-Fa-f]+$/) -> {:ok, String.upcase(clean)}
      true -> {:error, {:unexpected_response, clean}}
    end
  end

  @doc """
  Разбирает статус оси из 6-символьного hex ответа "ccbbaa".

    aa byte1: B0=Tracking/Goto, B1=CCW/CW, B2=Fast/Slow
    bb byte2: B0=Running/Stopped, B1=Blocked
    cc byte3: B0=Init done, B1=Level switch
  """
  def parse_status(response) do
    clean = String.upcase(String.trim(response))

    # Протокол :f возвращает ровно 3 байта = 6 hex символов.
    # Нечётная длина означает что UART разбил ответ на куски —
    # parse_complete сработал по но данные неполные.
    # Паддим СПРАВА нулями до 6: "2110" → "211000", байты aa=0x21 bb=0x10 cc=0x00.
    # pad_leading (старый код) давал "000211" → aa=0x00 bb=0x02 aa=0x11 — сдвиг байт!
    cond do
      rem(String.length(clean), 2) != 0 ->
        # Нечётная длина — неполный ответ, добавить 0 для выравнивания
        parse_status_bytes(String.pad_trailing(clean <> "0", 6, "0"), clean)
      true ->
        parse_status_bytes(String.pad_trailing(clean, 6, "0"), clean)
    end
  end

  defp parse_status_bytes(padded, raw) do
    case padded do
      <<a_hex::binary-size(2), b_hex::binary-size(2), c_hex::binary-size(2)>> ->
        {byte1, _} = Integer.parse(a_hex, 16)
        {byte2, _} = Integer.parse(b_hex, 16)
        {byte3, _} = Integer.parse(c_hex, 16)
        {:ok, %{
          # byte1: режим и направление (обычная логика — бит=1 означает да)
          tracking_mode: (byte1 &&& 0x01) != 0,
          direction_ccw: (byte1 &&& 0x02) != 0,
          high_speed:    (byte1 &&& 0x04) != 0,
          # byte2: ИНВЕРТИРОВАННАЯ логика — бит=0 означает активно!
          # bit0: 0=running, 1=stopped
          # bit1: 0=normal,  1=blocked
          running:       (byte2 &&& 0x01) == 0,
          blocked:       (byte2 &&& 0x02) != 0,
          # byte3: статус инициализации (обычная логика)
          initialized:   (byte3 &&& 0x01) != 0,
          level_switch:  (byte3 &&& 0x02) != 0,
          raw:           raw
        }}
      _ ->
        {:error, :invalid_status_response}
    end
  end

  @doc """
  Разбирает 24-bit little-endian значение (CPR, TMR_Freq, T1 и др.)

    "ccbbaa" → value = (aa << 16) | (bb << 8) | cc
    "00B289" → 0x89B200 = 9_024_000
  """
  def parse_24bit(response) do
    clean = String.upcase(String.trim(response))
    case clean do
      <<c_hex::binary-size(2), b_hex::binary-size(2), a_hex::binary-size(2)>> ->
        {c, _} = Integer.parse(c_hex, 16)
        {b, _} = Integer.parse(b_hex, 16)
        {a, _} = Integer.parse(a_hex, 16)
        {:ok, (a <<< 16) ||| (b <<< 8) ||| c}
      _ ->
        {:error, :invalid_response}
    end
  end

  @doc "Разбирает 8-bit значение (high speed ratio и др.)"
  def parse_8bit(response) do
    clean = String.upcase(String.trim(response))
    case clean do
      <<hex::binary-size(2)>> ->
        {value, _} = Integer.parse(hex, 16)
        {:ok, value}
      _ ->
        {:error, :invalid_response}
    end
  end

  @doc """
  Разбирает позицию оси с offset 0x800000.

    raw=0x800000 → 0 шагов (HOME)
    raw=0x7FFFFF → -1 шаг
  """
  def parse_position(response) do
    with {:ok, raw} <- parse_24bit(response) do
      {:ok, raw - @position_offset}
    end
  end

  @doc "Декодирует сырую строку позиции в шаги (fallback → 0)"
  def decode_position(raw_string) do
    case parse_24bit(raw_string) do
      {:ok, raw} -> raw - @position_offset
      _          -> 0
    end
  end

  # ===========================================================================
  # Приватные
  # ===========================================================================

  defp byte_to_hex(b),
    do: Integer.to_string(b, 16) |> String.pad_leading(2, "0") |> String.upcase()

  defp parse_error_code(code) do
    case String.trim(code) do
      "00" -> :unknown_command
      "01" -> :command_length_error
      "02" -> :motor_not_stopped
      "03" -> :invalid_character
      "04" -> :not_initialized
      "05" -> :driver_sleeping
      "07" -> :pec_training_running
      "08" -> :no_valid_pec_data
      other -> {:unknown_error, other}
    end
  end
end
