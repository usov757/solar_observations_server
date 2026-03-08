defmodule SolarObservations.Workers.MountWorker do
  @moduledoc """
  GenServer для управления экваториальной монтировкой SkyWatcher через UART.

  ## Система координат и HOME положение

  HOME (0 шагов на обоих осях) = монтировка физически выровнена:
    - Полярная ось направлена на север (Полярную звезду)
    - Широта выставлена по месту наблюдения
    - Труба параллельна полярной оси → смотрит на полюс (Dec = +90°)

  ## Логика наводки от HOME

    axis1 (RA ось):  поворачивает Dec ось + трубу в плоскость RA Солнца
      target = HA × CPR/360
      где HA = LST - RA_солнца (часовой угол)
      HA > 0 → Солнце западнее меридиана → CW (DB2=0x0)
      HA < 0 → Солнце восточнее меридиана → CCW (DB2=0x1)

    axis2 (Dec ось): наклоняет трубу от полюса (+90°) до Dec Солнца
      target = (Dec_солнца - 90°) × CPR/360
      Для Солнца Dec ≈ ±23°, значит target всегда отрицательный → CCW (DB2=0x1)

  ## Слежение после наводки

    axis1 (RA):  непрерывно вращается со скоростью Солнца (T1 preset)
    axis2 (Dec): неподвижна (Dec Солнца меняется ~1'/час, корректируется каждые 30 мин)

  ## Протокол SkyWatcher Motor Controller

    Команды: ":" + cmd_char + channel("1"/"2"/"3") + data + CR
    Ответы:  "=" + data + CR (успех) | "!" + error_code + CR (ошибка)
    Данные:  24-bit little-endian hex, e.g. 0x123456 → "563412"
    Позиция: всегда с offset 0x800000 (send: pos+0x800000, receive: raw-0x800000)

  ## Команда Set Motion Mode (:G)

    DB1:
      B0: 0=Goto, 1=Tracking
      B1: 0=Slow/1=Fast для Tracking; 0=Fast/1=Slow для Goto  ← инвертировано!
    DB2:
      B0: 0=CW, 1=CCW
      B1: 0=North, 1=South

    ВАЖНО: направление (DB2.B0) должно соответствовать знаку target_steps.
      target_steps >= 0 → CW  (DB2 = 0x0)
      target_steps <  0 → CCW (DB2 = 0x1)
  """

  use GenServer
  import Bitwise
  require Logger

  @response_timeout         10_000
  @ping_command             ":e1\r"
  @dec_correction_interval  30 * 60 * 1_000   # 30 минут
  @position_offset          0x800000

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts) do
    port_name          = Keyword.fetch!(opts, :port_name)
    baud_rate          = Keyword.get(opts, :baud_rate, 9600)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, 5_000)
    GenServer.start_link(__MODULE__, {port_name, baud_rate, reconnect_interval}, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id:       __MODULE__,
      start:    {__MODULE__, :start_link, [opts]},
      shutdown: 35_000,
      type:     :worker
    }
  end

  @doc "Инициализация осей монтировки. channel: '1', '2', '3' (обе)"
  def initialize(channel \\ "3", timeout \\ @response_timeout)
      when channel in ["1", "2", "3"] do
    case send_command(":F#{channel}\r", timeout) do
      {:ok, _} -> :ok
      error    -> error
    end
  end

  @doc "Версия прошивки"
  def get_version(channel, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    send_command(":e#{channel}\r", timeout)
  end

  @doc "Статус оси"
  def get_status(channel, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    case send_command(":f#{channel}\r", timeout) do
      {:ok, response} -> parse_status_response(response)
      error           -> error
    end
  end

  @doc "Текущая позиция оси в шагах (от HOME)"
  def get_position(channel, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    case send_command(":j#{channel}\r", timeout) do
      {:ok, response} -> parse_position_response(response)
      error           -> error
    end
  end

  @doc "Запуск движения"
  def start_motion(channel, timeout \\ @response_timeout)
      when channel in ["1", "2", "3"] do
    case send_command(":J#{channel}\r", timeout) do
      {:ok, _} -> :ok
      error    -> error
    end
  end

  @doc """
  Плавная остановка.
  ВНИМАНИЕ: по протоколу после плавной остановки контроллер переходит в Tracking mode.
  Используй instant_stop/1 (:L) там, где это нежелательно.
  """
  def stop_motion(channel, timeout \\ @response_timeout)
      when channel in ["1", "2", "3"] do
    Logger.debug("Sending stop command to channel #{channel}")
    case send_command(":K#{channel}\r", timeout) do
      {:ok, _}           -> Logger.debug("Stop command accepted"); :ok
      {:error, :timeout} -> Logger.warning("Stop command timeout"); :ok
      error              -> Logger.error("Stop error: #{inspect(error)}"); error
    end
  end

  @doc "Мгновенная остановка. Не переводит контроллер в Tracking mode."
  def instant_stop(channel, timeout \\ @response_timeout)
      when channel in ["1", "2", "3"] do
    case send_command(":L#{channel}\r", timeout) do
      {:ok, _} -> :ok
      error    -> error
    end
  end

  @doc """
  Установка режима движения.

  db1:
    B0: 0=Goto, 1=Tracking
    B1: 0=Slow/1=Fast (Tracking); 0=Fast/1=Slow (Goto) ← биты инвертированы для Goto!
  db2:
    B0: 0=CW, 1=CCW
    B1: 0=North, 1=South

  Пример: GOTO CW   → set_motion_mode(ch, 0x0, 0x0)
          GOTO CCW  → set_motion_mode(ch, 0x0, 0x1)
          Tracking  → set_motion_mode(ch, 0x1, 0x0)
  """
  def set_motion_mode(channel, db1, db2, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    d1 = Integer.to_string(db1 &&& 0xF, 16)
    d2 = Integer.to_string(db2 &&& 0xF, 16)
    case send_command(":G#{channel}#{d1}#{d2}\r", timeout) do
      {:ok, _} -> :ok
      error    -> error
    end
  end

  @doc "Установка целевой позиции для GOTO (в шагах от HOME, может быть отрицательной)"
  def set_goto_target(channel, position, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    pos_hex = format_hex_position(position)
    case send_command(":S#{channel}#{pos_hex}\r", timeout) do
      {:ok, _} -> :ok
      error    -> error
    end
  end

  @doc "Установка периода шага T1 (скорость слежения)"
  def set_step_period(channel, period, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    Logger.debug("Setting step_period channel #{channel}: #{period}")
    period_hex = format_hex_24bit(period)
    case send_command(":I#{channel}#{period_hex}\r", timeout) do
      {:ok, _} -> :ok
      error    -> error
    end
  end

  @doc "Counts Per Revolution — шагов на полный оборот оси"
  def get_cpr(channel, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    case send_command(":a#{channel}\r", timeout) do
      {:ok, response} -> parse_24bit_response(response)
      error           -> error
    end
  end

  @doc "Таймерная частота контроллера (всегда channel 1 по протоколу)"
  def get_timer_freq(timeout \\ @response_timeout) do
    case send_command(":b1\r", timeout) do
      {:ok, response} -> parse_24bit_response(response)
      error           -> error
    end
  end

  @doc "Соотношение высокой и низкой скоростей"
  def get_high_speed_ratio(channel, timeout \\ @response_timeout)
      when channel in ["1", "2"] do
    case send_command(":g#{channel}\r", timeout) do
      {:ok, response} -> parse_8bit_response(response)
      error           -> error
    end
  end

  @doc "Режим сна"
  def set_sleep(channel, sleep, timeout \\ @response_timeout)
      when channel in ["1", "2", "3"] do
    mode = if sleep, do: "1", else: "0"
    case send_command(":B#{channel}#{mode}\r", timeout) do
      {:ok, _} -> :ok
      error    -> error
    end
  end

  @doc "Статусы обеих осей"
  def get_all_statuses(timeout \\ @response_timeout) do
    with {:ok, s1} <- get_status("1", timeout),
         {:ok, s2} <- get_status("2", timeout) do
      {:ok, %{axis1: s1, axis2: s2}}
    end
  end

  @doc "Проверка связи с монтировкой"
  def ping(timeout \\ 3_000) do
    case get_version("1", timeout) do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Полная диагностика"
  def check_connection(timeout \\ @response_timeout) do
    with {:ok, version}  <- get_version("1", timeout),
         {:ok, statuses} <- get_all_statuses(timeout),
         {:ok, pos1}     <- get_position("1", timeout),
         {:ok, pos2}     <- get_position("2", timeout) do
      {:ok, %{
        connected:      true,
        version:        version,
        axis1_status:   statuses.axis1,
        axis2_status:   statuses.axis2,
        axis1_position: pos1,
        axis2_position: pos2,
        timestamp:      DateTime.utc_now()
      }}
    else
      {:error, :timeout}       -> {:error, :mount_not_responding}
      {:error, :not_connected} -> {:error, :worker_not_connected}
      {:error, reason}         -> {:error, reason}
    end
  end

  @doc "Движется ли ось (сравнивает позицию дважды)"
  def is_motor_moving?(channel, interval_ms \\ 500) do
    with {:ok, pos1} <- get_position(channel) do
      Process.sleep(interval_ms)
      with {:ok, pos2} <- get_position(channel) do
        {:ok, abs(pos2 - pos1) > 2}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Главный API: наводка и слежение
  # ---------------------------------------------------------------------------

  @doc """
  Навести трубу на Солнце и запустить слежение.

  Алгоритм:
    1. Мгновенная остановка всех осей
    2. GOTO в HOME (0, 0) — с правильным направлением по знаку
    3. Пересчёт позиции Солнца (время ушло пока ехали домой)
    4. GOTO обеими осями одновременно к Солнцу
    5. Запуск слежения только по RA (axis1)

  Направление GOTO определяется знаком target_steps:
    axis1: HA > 0 → CW; HA < 0 → CCW
    axis2: (Dec - 90°) всегда < 0 → CCW
  """
  def goto_sun(timeout \\ 120_000) do
    Logger.info("Starting Sun pointing procedure...")
    do_goto_sun(timeout)
  end

  @doc """
  Запустить солнечное слежение по RA оси.
  Dec ось остаётся неподвижной.
  Автоматически корректирует Dec каждые 30 минут.
  """
  def start_solar_tracking(cpr \\ nil, tmr_freq \\ nil) do
    Logger.info("Starting solar tracking...")
    with {:ok, cpr}      <- resolve_or_fetch(:cpr, cpr),
         {:ok, tmr_freq} <- resolve_or_fetch(:tmr_freq, tmr_freq),
         :ok             <- ensure_axis_stopped("1") do

      # T1 = TMR_Freq / Speed_CountsPerSec
      # Speed_CountsPerSec = solar_deg_per_sec * CPR / 360
      # solar_deg_per_sec = 360/86164.1 (сидерический) * 365.25/366.25 (поправка)
      solar_deg_per_sec = 360.0 / 86_164.1 * (365.25 / 366.25)
      t1_preset = round(tmr_freq * 360.0 / solar_deg_per_sec / cpr)

      Logger.info("Solar tracking: CPR=#{cpr}, TMR=#{tmr_freq}, T1=#{t1_preset}")

      # DB1: 0x1 = Tracking mode, B1=0 = Slow (нормальная скорость)
      # DB2: 0x0 = CW (Солнце движется на запад, RA ось компенсирует вращая на восток)
      with :ok <- set_motion_mode("1", 0x1, 0x0),
           :ok <- set_step_period("1", t1_preset),
           :ok <- start_motion("1"),
           {:ok, status} <- get_status("1") do

        if status.running do
          Logger.info("✓ Solar tracking active on RA axis, T1=#{t1_preset}")
          GenServer.cast(__MODULE__, {:start_dec_correction, cpr, tmr_freq})
          {:ok, %{t1_preset: t1_preset, cpr: cpr, tmr_freq: tmr_freq}}
        else
          Logger.error("✗ axis1 not running after start")
          {:error, :tracking_did_not_start}
        end
      end
    end
  end

  @doc """
  Остановить слежение и вернуться в HOME (0, 0).
  """
  def stop_and_return_home(timeout \\ 60_000) do
    Logger.info("Stopping tracking and returning to HOME...")
    GenServer.cast(__MODULE__, :cancel_dec_correction)
    with :ok <- instant_stop("3"),
         _   <- Process.sleep(300),
         :ok <- do_goto("1", 0),
         :ok <- do_goto("2", 0),
         :ok <- wait_for_stop("1", timeout),
         :ok <- wait_for_stop("2", timeout),
         :ok <- instant_stop("3") do
      Logger.info("✓ At HOME position (0, 0)")
      :ok
    end
  end

  @doc """
  Ручная синхронизация: запомнить что труба сейчас смотрит на Солнце.
  """
  def sync_to_sun() do
    with {:ok, sun}  <- get_sun_position(),
         #:ok         <- check_sun_visible(sun),
         {:ok, pos1} <- get_position("1"),
         {:ok, pos2} <- get_position("2") do

      calibration = %{
        axis1_steps: pos1,
        axis2_steps: pos2,
        ra_deg:      sun.ra,
        dec_deg:     sun.dec,
        timestamp:   DateTime.utc_now()
      }
      GenServer.cast(__MODULE__, {:set_calibration, calibration})
      Logger.info("""
      ✓ Sync complete:
        Axis1: #{pos1} steps = RA #{Float.round(sun.ra, 4)}°
        Axis2: #{pos2} steps = Dec #{Float.round(sun.dec, 4)}°
      """)
      {:ok, calibration}
    end
  end

  @doc "Текущее положение Солнца"
  def get_sun_position() do
    lat = Application.get_env(:solar_observations, :observer_latitude)
    lon = Application.get_env(:solar_observations, :observer_longitude)
    now = DateTime.utc_now()
    {az, alt, ra, dec, ha} = calculate_sun_position(now, lat, lon)
    {:ok, %{
      azimuth:    az,
      altitude:   alt,
      ra:         ra,
      dec:        dec,
      hour_angle: ha,
      timestamp:  now,
      observer:   %{latitude: lat, longitude: lon}
    }}
  end

  # ===========================================================================
  # Private: send
  # ===========================================================================

  defp send_command(command, timeout) do
    GenServer.call(__MODULE__, {:send_command, command, timeout}, timeout * 2)
  end

  # ===========================================================================
  # GenServer: init
  # ===========================================================================

  @impl true
  def init({port_name, baud_rate, reconnect_interval}) do
    Logger.info("Starting MountWorker on #{port_name} at #{baud_rate} baud")
    Process.flag(:trap_exit, true)
    {:ok, uart_pid} = Circuits.UART.start_link()
    Process.monitor(uart_pid)
    Circuits.UART.configure(uart_pid, active: true)
    send(self(), :connect)

    {:ok, %{
      uart_pid:                  uart_pid,
      connected:                 false,
      port_name:                 port_name,
      baud_rate:                 baud_rate,
      reconnect_interval:        reconnect_interval,
      request_queue:             [],
      current_request:           nil,
      response_buffer:           "",
      last_successful_command:   nil,
      connection_monitor_ref:    nil,
      connection_check_interval: 30_000,
      consecutive_timeouts:      0,
      max_consecutive_timeouts:  3,
      calibration:               nil,
      home_position:             %{axis1: 0, axis2: 0},
      return_home_pending:       false,
      dec_correction_ref:        nil,
      last_cpr:                  nil,
      last_tmr_freq:             nil
    }}
  end

  # ===========================================================================
  # Graceful shutdown: вернуться в HOME перед остановкой
  # ===========================================================================

  @impl true
  def terminate(reason, state) do
    Logger.warning("MountWorker terminating: #{inspect(reason)}")

    if state.connected do
      Logger.info("Emergency stop and returning HOME before shutdown...")

      if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)

      # Мгновенная остановка
      Circuits.UART.write(state.uart_pid, ":L3\r")
      Process.sleep(300)

      # GOTO HOME — направление определяется текущей позицией
      send_goto_home_uart(state.uart_pid, state.home_position.axis1, "1")
      send_goto_home_uart(state.uart_pid, state.home_position.axis2, "2")

      dist    = abs(state.home_position.axis1) + abs(state.home_position.axis2)
      wait_ms = min(dist * 10, 30_000)
      Logger.info("Waiting #{wait_ms}ms for HOME return...")
      Process.sleep(wait_ms)

      Circuits.UART.close(state.uart_pid)
      Logger.info("✓ Mount at HOME, UART closed")
    end

    :ok
  end

  # Отправляет GOTO HOME команды напрямую через UART (без GenServer queue)
  defp send_goto_home_uart(uart_pid, current_steps, channel) do
    # Направление: если сейчас > 0, нужно ехать назад (CCW), и наоборот
    direction = if current_steps >= 0, do: "0", else: "1"
    Circuits.UART.write(uart_pid, ":G#{channel}0#{direction}\r"); Process.sleep(100)
    Circuits.UART.write(uart_pid, ":S#{channel}#{format_hex_position(0)}\r"); Process.sleep(100)
    Circuits.UART.write(uart_pid, ":J#{channel}\r"); Process.sleep(100)
  end

  # ===========================================================================
  # GenServer: call handlers
  # ===========================================================================

  @impl true
  def handle_call({:send_command, command, timeout}, from, %{current_request: nil} = state) do
    {:noreply, execute_command(state, from, command, timeout)}
  end

  def handle_call({:send_command, command, timeout}, from, state) do
    {:noreply, %{state | request_queue: state.request_queue ++ [{from, command, timeout}]}}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # ===========================================================================
  # GenServer: cast handlers
  # ===========================================================================

  @impl true
  def handle_cast({:set_calibration, cal}, state) do
    Logger.info("Calibration saved: #{inspect(cal)}")
    {:noreply, %{state | calibration: cal}}
  end

  def handle_cast({:start_dec_correction, cpr, tmr_freq}, state) do
    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
    ref = Process.send_after(self(), :correct_dec, @dec_correction_interval)
    {:noreply, %{state | dec_correction_ref: ref, last_cpr: cpr, last_tmr_freq: tmr_freq}}
  end

  def handle_cast(:cancel_dec_correction, state) do
    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
    {:noreply, %{state | dec_correction_ref: nil}}
  end

  # ===========================================================================
  # GenServer: info handlers
  # ===========================================================================

  # --- Подключение ---

  @impl true
  def handle_info(:connect, %{connected: false} = state) do
    opts = [
      baud_rate: state.baud_rate,
      parity:    :none,
      stop_bits: 1,
      data_bits: 8,
      active:    true
    ]
    case Circuits.UART.open(state.uart_pid, state.port_name, opts) do
      :ok ->
        Logger.info("Connected to #{state.port_name}")
        ref = schedule_connection_check(state.connection_check_interval)
        send(self(), :do_init_mount)
        {:noreply, %{state |
          connected:              true,
          connection_monitor_ref: ref,
          consecutive_timeouts:   0
        }}
      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}, retrying...")
        schedule_reconnect(state.reconnect_interval)
        {:noreply, state}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  # --- Инициализация монтировки ---

  @impl true
  def handle_info(:do_init_mount, state) do
    Logger.info("Auto-initializing mount...")
    case Circuits.UART.write(state.uart_pid, ":F3\r") do
      :ok ->
        Process.send_after(self(), {:command_timeout, :init_mount}, @response_timeout)
        {:noreply, %{state |
          current_request: {:init_mount, ":F3\r", @response_timeout},
          response_buffer: ""
        }}
      {:error, reason} ->
        Logger.error("Failed to send init: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # --- Сохранение HOME позиции ---

  @impl true
  def handle_info(:save_home_position, state) do
    Logger.info("Reading home position axis1...")
    case Circuits.UART.write(state.uart_pid, ":j1\r") do
      :ok ->
        Process.send_after(self(), {:command_timeout, :home_pos1}, @response_timeout)
        {:noreply, %{state |
          current_request: {:home_pos1, ":j1\r", @response_timeout},
          response_buffer: ""
        }}
      {:error, reason} ->
        Logger.error("Failed to read home pos1: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:save_home_position_axis2, state) do
    Logger.info("Reading home position axis2...")
    case Circuits.UART.write(state.uart_pid, ":j2\r") do
      :ok ->
        Process.send_after(self(), {:command_timeout, :home_pos2}, @response_timeout)
        {:noreply, %{state |
          current_request: {:home_pos2, ":j2\r", @response_timeout},
          response_buffer: ""
        }}
      {:error, reason} ->
        Logger.error("Failed to read home pos2: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # --- Возврат в HOME после переподключения ---

  @impl true
  def handle_info(:return_home_after_reconnect, state) do
    Logger.info("Returning HOME after reconnect...")
    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)

    Circuits.UART.write(state.uart_pid, ":L3\r")
    Process.sleep(300)

    send_goto_home_uart(state.uart_pid, state.home_position.axis1, "1")
    send_goto_home_uart(state.uart_pid, state.home_position.axis2, "2")

    Logger.info("HOME GOTO commands sent after reconnect")
    {:noreply, %{state | dec_correction_ref: nil}}
  end

  # --- Коррекция Dec каждые 30 минут ---

  @impl true
  def handle_info(:correct_dec, state) do
    Logger.info("Dec correction check...")

    result =
      with {:ok, sun}  <- get_sun_position(),
           {:ok, cpr}  <- resolve_or_fetch(:cpr, state.last_cpr),
           {:ok, pos2} <- get_position("2") do

        # target всегда < 0 (Dec Солнца < 90°), поэтому do_goto выберет CCW
        target_dec_steps = round((sun.dec - 90.0) * cpr / 360.0)
        delta = target_dec_steps - pos2

        if abs(delta) > 100 do
          Logger.info("Dec correction: pos=#{pos2}, target=#{target_dec_steps}, delta=#{delta}")
          # Пауза RA слежения
          instant_stop("1")
          Process.sleep(300)
          # Коррекция Dec — направление определится знаком delta автоматически
          do_goto("2", target_dec_steps)
          wait_for_stop("2", 30_000)
          instant_stop("2")
          Process.sleep(300)
          # Возобновляем RA слежение
          start_solar_tracking(cpr, state.last_tmr_freq)
        else
          Logger.debug("Dec correction skipped, delta=#{delta} steps < 100")
        end
        :ok
      end

    if result != :ok, do: Logger.warning("Dec correction failed: #{inspect(result)}")

    ref = Process.send_after(self(), :correct_dec, @dec_correction_interval)
    {:noreply, %{state | dec_correction_ref: ref}}
  end

  # --- Проверка соединения ---

  @impl true
  def handle_info(:check_connection, state) do
    if state.connection_monitor_ref, do: Process.cancel_timer(state.connection_monitor_ref)

    new_state =
      if state.current_request != nil do
        Logger.debug("Connection check skipped — command in progress")
        state
      else
        case Circuits.UART.write(state.uart_pid, @ping_command) do
          :ok ->
            Process.send_after(self(), {:command_timeout, :connection_check}, 3_000)
            %{state |
              current_request: {:connection_check, @ping_command, 3_000},
              response_buffer: ""
            }
          {:error, reason} ->
            Logger.error("Ping write failed: #{inspect(reason)}")
            reconnect(state)
        end
      end

    ref = schedule_connection_check(state.connection_check_interval)
    {:noreply, %{new_state | connection_monitor_ref: ref}}
  end

  # --- Таймаут команды ---

  @impl true
  def handle_info({:command_timeout, timeout_from}, state) do
    case state.current_request do
      {^timeout_from, _, _} ->
        Logger.warning("Timeout: #{inspect(timeout_from)}")

        new_state =
          cond do
            timeout_from == :connection_check ->
              handle_ping_timeout(state)

            timeout_from in [:init_mount, :home_pos1, :home_pos2] ->
              Logger.warning("Internal command timeout: #{timeout_from}")
              state

            true ->
              GenServer.reply(timeout_from, {:error, :timeout})
              state
          end

        {:noreply, process_next_command(%{new_state |
          current_request: nil,
          response_buffer: ""
        })}

      _ ->
        {:noreply, state}
    end
  end

  # --- Данные от UART ---

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) do
    Logger.debug("← Raw: #{inspect(data)}")
    {:noreply, handle_response_data(state, data)}
  end

  # --- UART процесс упал ---

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("UART process down: #{inspect(reason)}")
    {:noreply, reconnect(state)}
  end

  def handle_info({:EXIT, _ref, :normal}, state) do
    Logger.warning("UART exited normally")
    {:noreply, reconnect(state)}
  end

  # ===========================================================================
  # Private: command execution
  # ===========================================================================

  defp execute_command(%{connected: false} = state, from, _command, _timeout) do
    GenServer.reply(from, {:error, :not_connected})
    state
  end

  defp execute_command(state, from, command, timeout) do
    Logger.debug("→ Sending: #{inspect(command)}")
    case Circuits.UART.write(state.uart_pid, command) do
      :ok ->
        Process.send_after(self(), {:command_timeout, from}, timeout)
        %{state | current_request: {from, command, timeout}, response_buffer: ""}
      {:error, reason} ->
        Logger.error("Write failed: #{inspect(reason)}")
        GenServer.reply(from, {:error, reason})
        reconnect(state)
    end
  end

  defp handle_response_data(%{current_request: nil} = state, _data) do
    Logger.warning("Data received without pending request")
    state
  end

  defp handle_response_data(%{current_request: {from, cmd, _}} = state, data) do
    buffer = state.response_buffer <> data

    case parse_complete_response(buffer) do
      {:complete, response, rest} ->
        Logger.debug("✓ Response: #{inspect(response)}")
        result = parse_response(response)

        new_state =
          cond do
            from == :connection_check ->
              case result do
                {:ok, _} ->
                  %{state |
                    consecutive_timeouts: 0,
                    last_successful_command: %{command: cmd, timestamp: DateTime.utc_now()}
                  }
                {:error, reason} ->
                  Logger.warning("Ping error: #{inspect(reason)}")
                  handle_ping_timeout(state)
              end

            from == :init_mount ->
              case result do
                {:ok, _} ->
                  Logger.info("✓ Mount initialized")
                  if state.return_home_pending do
                    send(self(), :return_home_after_reconnect)
                    %{state | return_home_pending: false}
                  else
                    send(self(), :save_home_position)
                    state
                  end
                {:error, reason} ->
                  Logger.error("Init failed: #{inspect(reason)}")
                  state
              end

            from == :home_pos1 ->
              case result do
                {:ok, raw_str} ->
                  pos1 = parse_raw_position(raw_str)
                  Logger.info("Home axis1 = #{pos1} steps")
                  send(self(), :save_home_position_axis2)
                  %{state | home_position: %{state.home_position | axis1: pos1}}
                {:error, reason} ->
                  Logger.warning("home_pos1 error: #{inspect(reason)}")
                  state
              end

            from == :home_pos2 ->
              case result do
                {:ok, raw_str} ->
                  pos2 = parse_raw_position(raw_str)
                  Logger.info("Home axis2 = #{pos2} steps")
                  Logger.info("✓ HOME saved: axis1=#{state.home_position.axis1}, axis2=#{pos2}")
                  %{state | home_position: %{state.home_position | axis2: pos2}}
                {:error, reason} ->
                  Logger.warning("home_pos2 error: #{inspect(reason)}")
                  state
              end

            true ->
              GenServer.reply(from, result)
              case result do
                {:ok, _} ->
                  %{state |
                    consecutive_timeouts: 0,
                    last_successful_command: %{command: cmd, timestamp: DateTime.utc_now()}
                  }
                _ -> state
              end
          end

        process_next_command(%{new_state | current_request: nil, response_buffer: rest})

      {:incomplete, new_buffer} ->
        %{state | response_buffer: new_buffer}
    end
  end

  defp handle_ping_timeout(state) do
    timeouts = state.consecutive_timeouts + 1
    Logger.warning("Ping timeout #{timeouts}/#{state.max_consecutive_timeouts}")
    if timeouts >= state.max_consecutive_timeouts do
      Logger.error("CONNECTION LOST — reconnecting...")
      reconnect(state)
    else
      %{state | consecutive_timeouts: timeouts}
    end
  end

  defp reconnect(state) do
    if state.current_request do
      {from, _, _} = state.current_request
      unless from in [:connection_check, :init_mount, :home_pos1, :home_pos2] do
        GenServer.reply(from, {:error, :connection_lost})
      end
    end
    Enum.each(state.request_queue, fn {from, _, _} ->
      GenServer.reply(from, {:error, :connection_lost})
    end)

    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
    Circuits.UART.close(state.uart_pid)
    schedule_reconnect(state.reconnect_interval)

    %{state |
      connected:            false,
      current_request:      nil,
      request_queue:        [],
      response_buffer:      "",
      consecutive_timeouts: 0,
      dec_correction_ref:   nil,
      return_home_pending:  true
    }
  end

  defp process_next_command(%{request_queue: []} = state), do: state
  defp process_next_command(%{request_queue: [{from, cmd, timeout} | rest]} = state) do
    execute_command(%{state | request_queue: rest}, from, cmd, timeout)
  end

  defp schedule_reconnect(interval),
    do: Process.send_after(self(), :connect, interval)

  defp schedule_connection_check(interval),
    do: Process.send_after(self(), :check_connection, interval)

  # ===========================================================================
  # Private: наводка на Солнце
  # ===========================================================================

  defp do_goto_sun(timeout) do
    with {:ok, sun} <- get_sun_position(),
         #:ok        <- check_sun_visible(sun),
         {:ok, cpr} <- get_cpr("1"),
         {:ok, tmr} <- get_timer_freq() do

      # Шаг 1: мгновенная остановка и возврат в HOME
      Logger.info("Returning to HOME before pointing...")
      with :ok <- instant_stop("3"),
           _   <- Process.sleep(300),
           :ok <- do_goto("1", 0),
           :ok <- do_goto("2", 0),
           :ok <- wait_for_stop("1", 60_000),
           :ok <- wait_for_stop("2", 60_000),
           :ok <- instant_stop("3"),
           _   <- Process.sleep(500) do

        Logger.info("✓ At HOME — calculating Sun position...")

        # Шаг 2: пересчитать позицию Солнца (пока ехали домой время прошло)
        with {:ok, sun2} <- get_sun_position() do
          lon = Application.get_env(:solar_observations, :observer_longitude)
          lst = calculate_lst(DateTime.utc_now(), lon)

          # Часовой угол: на сколько градусов Солнце ушло от меридиана
          # HA > 0 → Солнце западнее меридиана (уже прошло кульминацию) → CW
          # HA < 0 → Солнце восточнее меридиана (ещё не прошло) → CCW
          ha = lst - sun2.ra
          ha = cond do
            ha >  180.0 -> ha - 360.0
            ha < -180.0 -> ha + 360.0
            true        -> ha
          end

          steps_per_deg = cpr / 360.0

          # axis1 (RA ось): разворот в плоскость RA Солнца
          # В HOME = меридиан. target = HA × CPR/360
          # Знак HA определяет направление: do_goto выберет CW/CCW сам
          axis1_steps = round(ha * steps_per_deg)

          # axis2 (Dec ось): наклон от полюса до Dec Солнца
          # В HOME труба смотрит на полюс = Dec +90°.
          # target = (Dec_солнца - 90°) × CPR/360
          # Для любого Dec < 90° → target < 0 → do_goto выберет CCW
          axis2_steps = round((sun2.dec - 90.0) * steps_per_deg)

          Logger.info("""
          Pointing to Sun:
            LST      = #{Float.round(lst, 4)}°
            Sun RA   = #{Float.round(sun2.ra, 4)}°
            HA       = #{Float.round(ha, 4)}°       → axis1 = #{axis1_steps} steps (#{direction_label(axis1_steps)})
            Sun Dec  = #{Float.round(sun2.dec, 4)}°
            Dec-90°  = #{Float.round(sun2.dec - 90.0, 4)}° → axis2 = #{axis2_steps} steps (#{direction_label(axis2_steps)})
            Azimuth  = #{Float.round(sun2.azimuth, 2)}°
            Altitude = #{Float.round(sun2.altitude, 2)}°
          """)

          # Шаг 3: GOTO обеими осями одновременно
          # do_goto сам определяет направление по знаку target_steps
          # После прихода используем instant_stop (:L), не :K,
          # чтобы контроллер не включил Tracking mode самостоятельно
          with :ok <- do_goto("1", axis1_steps),
               :ok <- do_goto("2", axis2_steps),
               :ok <- wait_for_stop("1", timeout),
               :ok <- wait_for_stop("2", timeout),
               :ok <- instant_stop("3"),
               _   <- Process.sleep(500) do

            Logger.info("✓ GOTO complete — tube pointed at Sun")

            # Шаг 4: слежение только по RA (axis1)
            start_solar_tracking(cpr, tmr)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ИСПРАВЛЕНИЕ: do_goto теперь определяет направление по знаку target_steps.
  #
  # По протоколу (:G command, DB2.B0):
  #   0 = CW  (по часовой стрелке)  → target_steps >= 0
  #   1 = CCW (против часовой)      → target_steps < 0
  #
  # Без этого контроллер всегда крутил в одну сторону (CW),
  # и axis2 никогда не добиралась до Dec Солнца.
  # ---------------------------------------------------------------------------
  defp do_goto(channel, target_steps) do
    # DB1: 0x0 = Goto mode, B1=0 = Fast (для Goto B1=0 означает Fast)
    # DB2: определяется знаком target_steps
    direction_db2 = if target_steps >= 0, do: 0x0, else: 0x1

    with :ok <- set_motion_mode(channel, 0x0, direction_db2),
         :ok <- set_goto_target(channel, target_steps),
         :ok <- start_motion(channel) do
      Logger.debug("GOTO ch#{channel} → #{target_steps} steps (#{direction_label(target_steps)})")
      :ok
    end
  end

  # Ожидание завершения GOTO по стабилизации позиции.
  # Намеренно НЕ используем running=false из get_status,
  # потому что после :K контроллер сам включает Tracking mode.
  defp wait_for_stop(channel, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    Process.sleep(200)
    do_wait_for_stop(channel, deadline, nil, 0)
  end

  defp do_wait_for_stop(channel, deadline, last_pos, stable_count) do
    if System.monotonic_time(:millisecond) > deadline do
      Logger.error("GOTO timeout on axis #{channel}")
      {:error, :goto_timeout}
    else
      case get_position(channel) do
        {:ok, pos} ->
          cond do
            last_pos == pos and stable_count >= 2 ->
              Logger.debug("Axis #{channel} at #{pos} — stable ✓")
              :ok
            last_pos == pos ->
              Process.sleep(300)
              do_wait_for_stop(channel, deadline, pos, stable_count + 1)
            true ->
              Logger.debug("Axis #{channel} moving: #{last_pos} → #{pos}")
              Process.sleep(300)
              do_wait_for_stop(channel, deadline, pos, 0)
          end
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_sun_visible(%{altitude: alt}) when alt < 5.0 do
    Logger.error("Sun too low: #{Float.round(alt, 1)}°")
    {:error, {:sun_too_low, alt}}
  end
  defp check_sun_visible(%{altitude: alt}) do
    Logger.info("Sun altitude: #{Float.round(alt, 1)}° — OK")
    :ok
  end

  defp ensure_axis_stopped(channel) do
    case get_status(channel) do
      {:ok, %{running: true}} ->
        Logger.info("Stopping axis #{channel}...")
        with :ok <- instant_stop(channel) do
          Process.sleep(300)
          :ok
        end
      {:ok, %{running: false}} -> :ok
      {:error, reason}         -> {:error, reason}
    end
  end

  defp resolve_or_fetch(:cpr, nil),      do: get_cpr("1")
  defp resolve_or_fetch(:cpr, val),      do: {:ok, val}
  defp resolve_or_fetch(:tmr_freq, nil), do: get_timer_freq()
  defp resolve_or_fetch(:tmr_freq, val), do: {:ok, val}

  # Вспомогательная метка для логов
  defp direction_label(steps) when steps >= 0, do: "CW"
  defp direction_label(_steps),                do: "CCW"

  # ===========================================================================
  # Private: астрономические расчёты
  # ===========================================================================

  @doc false
  def calculate_sun_position(%DateTime{} = utc, lat_deg, lon_deg) do
    jd = datetime_to_jd(utc)
    t  = (jd - 2_451_545.0) / 36_525.0

    Logger.debug("[SUN] UTC=#{DateTime.to_iso8601(utc)} lat=#{lat_deg} lon=#{lon_deg}")
    Logger.debug("[SUN] JD=#{jd} T=#{t}")

    l0    = mod360(280.46646 + 36_000.76983 * t)
    m_deg = mod360(357.52911 + 35_999.05029 * t - 0.0001537 * t * t)
    m_rad = deg2rad(m_deg)

    Logger.debug("[SUN] L0=#{l0}° M=#{m_deg}°")

    c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * :math.sin(m_rad)
      + (0.019993 - 0.000101 * t) * :math.sin(2.0 * m_rad)
      + 0.000289 * :math.sin(3.0 * m_rad)

    sun_lon = l0 + c - 0.00569 - 0.00478 * :math.sin(deg2rad(125.04 - 1934.136 * t))

    Logger.debug("[SUN] C=#{c} sun_lon=#{sun_lon}°")

    epsilon = deg2rad(23.439291111 - 0.013004167 * t)
    sl      = deg2rad(sun_lon)

    ra_rad  = :math.atan2(:math.cos(epsilon) * :math.sin(sl), :math.cos(sl))
    dec_rad = :math.asin(:math.sin(epsilon) * :math.sin(sl))
    ra_deg  = mod360(rad2deg(ra_rad))
    dec_deg = rad2deg(dec_rad)

    Logger.debug("[SUN] RA_raw=#{rad2deg(ra_rad)}° RA=#{ra_deg}° Dec=#{dec_deg}°")

    lst    = calculate_lst(utc, lon_deg)
    ha_raw = mod360(lst - ra_deg)
    ha_deg = if ha_raw > 180, do: ha_raw - 360.0, else: ha_raw

    Logger.debug("[SUN] LST=#{lst}° HA_raw(mod360)=#{ha_raw}° HA=#{ha_deg}°")

    lat    = deg2rad(lat_deg)
    ha_rad = deg2rad(ha_deg)

    term1   = :math.sin(lat) * :math.sin(dec_rad)
    term2   = :math.cos(lat) * :math.cos(dec_rad) * :math.cos(ha_rad)
    sin_alt = term1 + term2
    alt_deg = rad2deg(:math.asin(sin_alt))

    Logger.debug("[SUN] sin(lat)=#{:math.sin(lat)} sin(dec)=#{:math.sin(dec_rad)}")
    Logger.debug("[SUN] term1=#{term1} term2=#{term2} sin_alt=#{sin_alt}")
    Logger.debug("[SUN] ALT=#{alt_deg}°  ← результат")

    cos_az = (:math.sin(dec_rad) - :math.sin(lat) * sin_alt)
           / (:math.cos(lat) * :math.cos(deg2rad(alt_deg)))
    cos_az = cos_az |> max(-1.0) |> min(1.0)
    az_deg = rad2deg(:math.acos(cos_az))
    az_deg = if :math.sin(ha_rad) > 0, do: 360.0 - az_deg, else: az_deg

    Logger.debug("[SUN] AZ=#{az_deg}°")

    {az_deg, alt_deg, ra_deg, dec_deg, ha_deg}
  end

  defp calculate_lst(%DateTime{} = utc, lon_deg) do
    jd   = datetime_to_jd(utc)
    jd0  = Float.floor(jd - 0.5) + 0.5
    t0   = (jd0 - 2_451_545.0) / 36_525.0
    ut_h = utc.hour + utc.minute / 60.0 + utc.second / 3600.0

    gmst_raw = 100.4606184 + 36_000.77004 * t0 + 0.000387933 * t0 * t0 + 360.98564724 * (ut_h / 24.0)
    gmst     = mod360(gmst_raw)
    lst      = mod360(gmst + lon_deg)

    Logger.debug("[LST] JD0=#{jd0} T0=#{t0} UT_h=#{ut_h}")
    Logger.debug("[LST] GMST_raw=#{gmst_raw} GMST=#{gmst}° LST=#{lst}°")

    lst
  end

  defp datetime_to_jd(%DateTime{} = dt) do
    ut = dt.hour / 24.0 + dt.minute / 1440.0 + dt.second / 86400.0
    {y, m} = if dt.month <= 2,
      do:   {dt.year - 1, dt.month + 12},
      else: {dt.year, dt.month}
    a = div(y, 100)
    b = 2 - a + div(a, 4)
    Float.floor(365.25 * (y + 4716)) + Float.floor(30.6001 * (m + 1)) + dt.day + ut + b - 1524.5
  end

  defp deg2rad(d), do: d * :math.pi() / 180.0
  defp rad2deg(r), do: r * 180.0 / :math.pi()

  defp mod360(x) do
    r = :math.fmod(x, 360.0)
    if r < 0.0, do: r + 360.0, else: r
  end

  # ===========================================================================
  # Private: протокол — кодирование
  # ===========================================================================

  # Кодирует позицию в шагах в 6-символьный hex для команды :S
  # Протокол: little-endian байты с offset 0x800000
  # Пример:  1 шаг → raw=0x800001 → "01" "00" "80" → "010080"
  # Пример: -1 шаг → raw=0x7FFFFF → "FF" "FF" "7F" → "FFFF7F"
  defp format_hex_position(steps) when is_integer(steps) do
    format_hex_24bit(steps + @position_offset)
  end

  # Кодирует 24-bit значение в little-endian hex строку
  # 0x123456 → byte_a=0x56, byte_b=0x34, byte_c=0x12 → "563412"
  defp format_hex_24bit(value) when is_integer(value) and value >= 0 do
    data   = value &&& 0xFFFFFF
    byte_a = (data >>> 16) &&& 0xFF   # старший
    byte_b = (data >>>  8) &&& 0xFF   # средний
    byte_c =  data         &&& 0xFF   # младший
    # little-endian: сначала младший байт
    byte_to_hex(byte_c) <> byte_to_hex(byte_b) <> byte_to_hex(byte_a)
  end

  defp byte_to_hex(b),
    do: Integer.to_string(b, 16) |> String.pad_leading(2, "0") |> String.upcase()

  # ===========================================================================
  # Private: протокол — разбор ответов
  # ===========================================================================

  defp parse_complete_response(buffer) do
    clean = String.replace(buffer, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    case String.split(clean, "\r", parts: 2) do
      [response, rest] -> {:complete, String.trim(response), rest}
      [incomplete]     -> {:incomplete, incomplete}
    end
  end

  defp parse_response(response) do
    clean = String.trim(response)
    cond do
      String.starts_with?(clean, "=") ->
        {:ok, String.slice(clean, 1..-1//1)}
      String.starts_with?(clean, "!") ->
        {:error, parse_error_code(String.slice(clean, 1..-1//1))}
      clean == "" ->
        {:ok, ""}
      String.match?(clean, ~r/^[0-9A-Fa-f]+$/) ->
        {:ok, String.upcase(clean)}
      true ->
        Logger.warning("Unexpected response: #{inspect(clean)}")
        {:error, {:unexpected_response, clean}}
    end
  end

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

  # Статус оси: разбор 3-6 hex символов (little-endian, 3 байта)
  # Формат ответа: "ccbbaa"
  #   aa (byte1): B0=Tracking/Goto, B1=CCW/CW, B2=Fast/Slow
  #   bb (byte2): B0=Running/Stopped, B1=Blocked/Normal
  #   cc (byte3): B0=Init done, B1=Level switch
  defp parse_status_response(response) do
    clean  = String.upcase(String.trim(response))
    padded = String.pad_leading(clean, 6, "0")

    case padded do
      <<c_hex::binary-size(2), b_hex::binary-size(2), a_hex::binary-size(2)>> ->
        {byte1, _} = Integer.parse(a_hex, 16)
        {byte2, _} = Integer.parse(b_hex, 16)
        {byte3, _} = Integer.parse(c_hex, 16)
        {:ok, %{
          tracking_mode: (byte1 &&& 0x01) != 0,
          direction_ccw: (byte1 &&& 0x02) != 0,
          high_speed:    (byte1 &&& 0x04) != 0,
          running:       (byte2 &&& 0x01) != 0,
          blocked:       (byte2 &&& 0x02) != 0,
          initialized:   (byte3 &&& 0x01) != 0,
          level_switch:  (byte3 &&& 0x02) != 0,
          raw:           clean
        }}
      _ ->
        Logger.error("Invalid status response: #{inspect(clean)}")
        {:error, :invalid_status_response}
    end
  end

  # Разбор 24-bit little-endian ответа (CPR, TMR_Freq, T1 и др.)
  # Ответ "ccbbaa" (little-endian):
  #   value = (aa << 16) | (bb << 8) | cc
  # Пример: "00B289" → cc="00", bb="B2", aa="89"
  #   value = (0x89 << 16) | (0xB2 << 8) | 0x00 = 0x89B200 = 9,024,000
  defp parse_24bit_response(response) do
    clean = String.upcase(String.trim(response))
    case clean do
      <<c_hex::binary-size(2), b_hex::binary-size(2), a_hex::binary-size(2)>> ->
        {c, _} = Integer.parse(c_hex, 16)
        {b, _} = Integer.parse(b_hex, 16)
        {a, _} = Integer.parse(a_hex, 16)
        {:ok, (a <<< 16) ||| (b <<< 8) ||| c}
      _ ->
        Logger.error("Invalid 24bit response: #{inspect(clean)}")
        {:error, :invalid_response}
    end
  end

  defp parse_8bit_response(response) do
    clean = String.upcase(String.trim(response))
    case clean do
      <<hex::binary-size(2)>> ->
        {value, _} = Integer.parse(hex, 16)
        {:ok, value}
      _ ->
        Logger.error("Invalid 8bit response: #{inspect(clean)}")
        {:error, :invalid_response}
    end
  end

  # Позиция оси: 24-bit с offset 0x800000
  # Ответ "000080" → raw=0x800000 → real = 0x800000 - 0x800000 = 0
  # Ответ "FFFF7F" → raw=0x7FFFFF → real = 0x7FFFFF - 0x800000 = -1
  defp parse_position_response(response) do
    case parse_24bit_response(response) do
      {:ok, raw} ->
        position = raw - @position_offset
        Logger.debug("Position raw=0x#{Integer.to_string(raw, 16)}, real=#{position}")
        {:ok, position}
      error ->
        error
    end
  end

  defp parse_raw_position(raw_string) do
    case parse_24bit_response(raw_string) do
      {:ok, raw} -> raw - @position_offset
      _          -> 0
    end
  end
end
