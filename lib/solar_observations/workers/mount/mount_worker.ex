defmodule SolarObservations.Workers.Mount.MountWorker do
  @moduledoc """
  GenServer для управления экваториальной монтировкой SkyWatcher через UART.

  Особенности:
    - При старте не требует наличия активной монтировки; ждёт появления в БД.
    - Периодически проверяет наличие/смену активной монтировки и переподключается.
    - Координаты монтировки (широта, долгота) берутся из активной записи.
  """

  use GenServer
  import Bitwise
  require Logger

  alias SolarObservations.Repo
  alias SolarObservations.Mount
  alias SolarObservations.Workers.Mount.Utils.Protocol
  alias SolarObservations.Workers.Mount.Utils.Pointing

  @response_timeout        10_000
  @ping_command            ":e1\r"
  @dec_correction_interval 30 * 60 * 1_000
  @chunk_degrees           330.0
  @stable_ticks_required   3
  @mount_check_interval    10_000   # как часто проверять активную монтировку (мс)

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts \\ []) do
    reconnect_interval = Keyword.get(opts, :reconnect_interval, 5_000)
    GenServer.start_link(__MODULE__, %{reconnect_interval: reconnect_interval}, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 35_000, type: :worker}
  end

  # Все публичные команды (кроме reload_mount/get_active_mount) должны быть обёрнуты
  # в with_mount/1, который проверяет наличие активной монтировки.
  defp with_mount(fun) do
    case GenServer.call(__MODULE__, :is_mount_ready) do
      true -> fun.()
      false -> {:error, :no_active_mount}
    end
  end

  # --- Команды монтировки (требуют активной монтировки) ---
  def initialize(channel \\ "3", timeout \\ @response_timeout) when channel in ["1", "2", "3"] do
    with_mount(fn -> send_command(":F#{channel}\r", timeout) end)
  end

  def get_version(channel, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn -> send_command(":e#{channel}\r", timeout) end)
  end

  def get_status(channel, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn ->
      case send_command(":f#{channel}\r", timeout) do
        {:ok, response} -> Protocol.parse_status(response)
        error -> error
      end
    end)
  end

  def get_position(channel, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn ->
      case send_command(":j#{channel}\r", timeout) do
        {:ok, response} -> Protocol.parse_position(response)
        error -> error
      end
    end)
  end

  def start_motion(channel, timeout \\ @response_timeout) when channel in ["1", "2", "3"] do
    with_mount(fn -> send_command(":J#{channel}\r", timeout) end)
  end

  def stop_motion(channel, timeout \\ @response_timeout) when channel in ["1", "2", "3"] do
    with_mount(fn ->
      case send_command(":K#{channel}\r", timeout) do
        {:ok, _} -> :ok
        {:error, :timeout} -> Logger.warning("Stop command timeout"); :ok
        error -> error
      end
    end)
  end

  def instant_stop(channel, timeout \\ @response_timeout) when channel in ["1", "2", "3"] do
    with_mount(fn -> send_command(":L#{channel}\r", timeout) end)
  end

  def set_motion_mode(channel, db1, db2, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn ->
      d1 = Integer.to_string(db1 &&& 0xF, 16)
      d2 = Integer.to_string(db2 &&& 0xF, 16)
      send_command(":G#{channel}#{d1}#{d2}\r", timeout)
    end)
  end

  def set_goto_target(channel, position, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn -> send_command(":S#{channel}#{Protocol.encode_position(position)}\r", timeout) end)
  end

  def set_step_period(channel, period, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn -> send_command(":I#{channel}#{Protocol.encode_24bit(period)}\r", timeout) end)
  end

  def get_cpr(channel, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn ->
      case send_command(":a#{channel}\r", timeout) do
        {:ok, response} -> Protocol.parse_24bit(response)
        error -> error
      end
    end)
  end

  def get_timer_freq(timeout \\ @response_timeout) do
    with_mount(fn ->
      case send_command(":b1\r", timeout) do
        {:ok, response} -> Protocol.parse_24bit(response)
        error -> error
      end
    end)
  end

  def get_high_speed_ratio(channel, timeout \\ @response_timeout) when channel in ["1", "2"] do
    with_mount(fn ->
      case send_command(":g#{channel}\r", timeout) do
        {:ok, response} -> Protocol.parse_8bit(response)
        error -> error
      end
    end)
  end

  def set_sleep(channel, sleep, timeout \\ @response_timeout) when channel in ["1", "2", "3"] do
    mode = if sleep, do: "1", else: "0"
    with_mount(fn -> send_command(":B#{channel}#{mode}\r", timeout) end)
  end

  def get_all_statuses(timeout \\ @response_timeout) do
    with_mount(fn ->
      with {:ok, s1} <- get_status("1", timeout),
           {:ok, s2} <- get_status("2", timeout) do
        {:ok, %{axis1: s1, axis2: s2}}
      end
    end)
  end

  def ping(timeout \\ 3_000) do
    with_mount(fn -> get_version("1", timeout) end)
  end

  def check_connection(timeout \\ @response_timeout) do
    with_mount(fn ->
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
    end)
  end

  def is_motor_moving?(channel, interval_ms \\ 500) do
    with_mount(fn ->
      with {:ok, pos1} <- get_position(channel) do
        Process.sleep(interval_ms)
        with {:ok, pos2} <- get_position(channel) do
          {:ok, abs(pos2 - pos1) > 2}
        end
      end
    end)
  end

  # --- Позиция Солнца (использует координаты активной монтировки) ---
  def get_sun_position do
    GenServer.call(__MODULE__, :get_sun_position, 5_000)
  end

  # --- Управление активной монтировкой ---
  def reload_mount do
    GenServer.cast(__MODULE__, :reload_mount)
  end

  def get_active_mount do
    GenServer.call(__MODULE__, :get_active_mount)
  end

  # ---------------------------------------------------------------------------
  # Главный API: наводка и слежение
  # ---------------------------------------------------------------------------

  def goto_sun(timeout \\ 120_000) do
    Logger.info("Starting Sun pointing procedure...")
    do_goto_sun(timeout)
  end

  @doc """
  Повернуть ось на заданное количество градусов от текущей позиции.

  channel: "1" (RA) или "2" (Dec)
  degrees: положительное → CW, отрицательное → CCW

  Большие углы автоматически разбиваются на чанки по @chunk_degrees
  чтобы не переполнить 24-bit регистр контроллера.

  ## Примеры
      MountWorker.goto_degrees("1", 5.0)    # RA +5° CW
      MountWorker.goto_degrees("2", -10.0)  # Dec -10° CCW
      MountWorker.goto_degrees("1", 360.0)  # Полный оборот, 2 чанка
  """
  def goto_degrees(channel, degrees) when channel in ["1", "2"] do
    with {:ok, cpr}      <- get_cpr("1"),
         {:ok, curr_pos} <- get_position(channel) do
      total_steps = round(degrees * cpr / 360.0)
      chunk_steps = round(@chunk_degrees * cpr / 360.0)
      chunks      = ceil(abs(total_steps) / chunk_steps)

      Logger.info("""
      ┌─ goto_degrees ───────────────────────
      │  channel    : #{channel}
      │  degrees    : #{degrees}°
      │  cpr        : #{cpr}
      │  current pos: #{curr_pos} steps
      │  total steps: #{total_steps}
      │  chunk size : #{chunk_steps} steps (#{@chunk_degrees}°)
      │  direction  : #{Pointing.direction_label(total_steps)}
      │  chunks     : #{chunks}
      └──────────────────────────────────────
      """)

      started_at = System.monotonic_time(:millisecond)
      result     = do_goto_chunked(channel, curr_pos, total_steps, cpr, chunk_steps, 1)

      case result do
        {:ok, final_pos} ->
          elapsed    = System.monotonic_time(:millisecond) - started_at
          actual_deg = Float.round((final_pos - curr_pos) * 360.0 / cpr, 2)
          Logger.info("""
          ┌─ goto_degrees done ──────────────────
          │  elapsed    : #{elapsed} ms
          │  expected   : #{degrees}°
          │  actual     : #{actual_deg}°
          │  steps done : #{final_pos - curr_pos} / #{total_steps}
          └──────────────────────────────────────
          """)
          {:ok, %{degrees: degrees, actual_degrees: actual_deg,
                  total_steps: total_steps, actual_pos: final_pos, elapsed_ms: elapsed}}
        error -> error
      end
    end
  end

  def start_solar_tracking(cpr \\ nil, tmr_freq \\ nil) do
    Logger.info("Starting solar tracking...")
    with {:ok, cpr}      <- resolve_or_fetch(:cpr, cpr),
         {:ok, tmr_freq} <- resolve_or_fetch(:tmr_freq, tmr_freq),
         :ok             <- ensure_axis_stopped("1") do

      t1_preset = Pointing.calculate_t1_preset(cpr, tmr_freq)
      Logger.info("Solar tracking: CPR=#{cpr}, TMR=#{tmr_freq}, T1=#{t1_preset}")

      with :ok <- set_motion_mode("1", 0x1, 0x0),
           :ok <- set_step_period("1", t1_preset),
           :ok <- start_motion("1"),
           {:ok, status} <- get_status("1") do
        if status.running do
          Logger.info("✓ Solar tracking active, T1=#{t1_preset}")
          GenServer.cast(__MODULE__, {:start_dec_correction, cpr, tmr_freq})
          GenServer.cast(__MODULE__, {:set_activity, {:tracking, cpr, tmr_freq}})
          {:ok, %{t1_preset: t1_preset, cpr: cpr, tmr_freq: tmr_freq}}
        else
          Logger.error("✗ axis1 not running after start")
          {:error, :tracking_did_not_start}
        end
      end
    end
  end

  def stop_and_return_home(timeout \\ 60_000) do
    Logger.info("Stopping tracking and returning to HOME...")
    GenServer.cast(__MODULE__, :cancel_dec_correction)
    GenServer.cast(__MODULE__, {:set_activity, nil})
    with :ok <- instant_stop("3"),
         _   <- Process.sleep(300),
         :ok <- do_goto_safe("1", 0),
         :ok <- do_goto_safe("2", 0),
         :ok <- wait_for_stop("1", timeout),
         :ok <- wait_for_stop("2", timeout),
         :ok <- instant_stop("3") do
      Logger.info("✓ At HOME (0, 0)")
      :ok
    end
  end

  def sync_to_sun do
    with {:ok, sun}  <- get_sun_position(),
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
      Logger.info("✓ Sync: axis1=#{pos1} steps = RA #{Float.round(sun.ra,4)}°, axis2=#{pos2} steps = Dec #{Float.round(sun.dec,4)}°")
      {:ok, calibration}
    end
  end

  # ===========================================================================
  # GenServer: init / terminate
  # ===========================================================================

  @impl true
  def init(%{reconnect_interval: reconnect_interval}) do
    Process.flag(:trap_exit, true)
    {:ok, uart_pid} = Circuits.UART.start_link()
    Process.monitor(uart_pid)
    Circuits.UART.configure(uart_pid, active: true)

    state = %{
      uart_pid:                  uart_pid,
      connected:                 false,
      port_name:                 nil,
      baud_rate:                 nil,
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
      last_tmr_freq:             nil,
      mount_initialized:         false,
      active_activity:           nil,
      # Новые поля
      active_mount_id:           nil,
      latitude:                  nil,
      longitude:                 nil,
      status:                    :waiting_for_mount,  # :waiting_for_mount | :connecting | :connected
      mount_check_timer:         nil
    }

    schedule_mount_check()
    Logger.info("MountWorker started. Waiting for active mount...")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning("MountWorker terminating: #{inspect(reason)}")
    if state.connected do
      if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
      Circuits.UART.write(state.uart_pid, ":L3\r")
      Process.sleep(300)
      send_goto_home_uart(state.uart_pid, state.home_position.axis1, "1")
      send_goto_home_uart(state.uart_pid, state.home_position.axis2, "2")
      wait_ms = min(abs(state.home_position.axis1) + abs(state.home_position.axis2), 30_000)
      Process.sleep(wait_ms)
      Circuits.UART.close(state.uart_pid)
      Logger.info("✓ Mount at HOME, UART closed")
    end
    :ok
  end

  # ===========================================================================
  # GenServer: call / cast (все handle_call сгруппированы здесь)
  # ===========================================================================

  @impl true
  def handle_call({:send_command, command, timeout}, from, %{current_request: nil} = state),
    do: {:noreply, execute_command(state, from, command, timeout)}

  def handle_call({:send_command, command, timeout}, from, state),
    do: {:noreply, %{state | request_queue: state.request_queue ++ [{from, command, timeout}]}}

  def handle_call(:get_state, _from, state),
    do: {:reply, state, state}

  # Новые клаузы для активной монтировки и позиции Солнца
  def handle_call(:is_mount_ready, _from, state) do
    ready = state.status == :connected and state.mount_initialized
    {:reply, ready, state}
  end

  def handle_call(:get_sun_position, _from, state) do
    case {state.status, state.latitude, state.longitude} do
      {:connected, lat, lon} when not is_nil(lat) and not is_nil(lon) ->
        now = DateTime.utc_now()
        lat_float = Decimal.to_float(lat)
        lon_float = Decimal.to_float(lon)
        result = Pointing.calculate_sun_position(now, lat_float, lon_float)
        {:reply, {:ok, result}, state}
      _ ->
        {:reply, {:error, :mount_not_ready}, state}
    end
  end

  def handle_call(:get_active_mount, _from, state) do
    if state.active_mount_id do
      mount = Repo.get(Mount, state.active_mount_id)
      {:reply, {:ok, mount}, state}
    else
      {:reply, {:error, :no_active_mount}, state}
    end
  end

  # Casts
  @impl true
  def handle_cast({:set_calibration, cal}, state),
    do: {:noreply, %{state | calibration: cal}}

  def handle_cast({:start_dec_correction, cpr, tmr_freq}, state) do
    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
    ref = Process.send_after(self(), :correct_dec, @dec_correction_interval)
    {:noreply, %{state | dec_correction_ref: ref, last_cpr: cpr, last_tmr_freq: tmr_freq}}
  end

  def handle_cast(:cancel_dec_correction, state) do
    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
    {:noreply, %{state | dec_correction_ref: nil}}
  end

  def handle_cast({:set_activity, activity}, state) do
    {:noreply, %{state | active_activity: activity}}
  end

  def handle_cast(:reload_mount, state) do
    send(self(), :check_active_mount)
    {:noreply, state}
  end

  # ===========================================================================
  # GenServer: info
  # ===========================================================================

  # Обработчик connect – сначала проверяем состояние ожидания
  def handle_info(:connect, %{status: :waiting_for_mount} = state) do
    Logger.debug("MountWorker in waiting_for_mount state, ignoring connect")
    {:noreply, state}
  end

  def handle_info(:connect, %{connected: false} = state) do
    opts = [baud_rate: state.baud_rate, parity: :none, stop_bits: 1, data_bits: 8, active: true]
    case Circuits.UART.open(state.uart_pid, state.port_name, opts) do
      :ok ->
        Logger.info("Connected to #{state.port_name}")
        send(self(), :do_init_mount)
        {:noreply, %{state | connected: true, consecutive_timeouts: 0, mount_initialized: false}}
      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}, retrying...")
        schedule_reconnect(state.reconnect_interval)
        {:noreply, state}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  @impl true
  def handle_info(:do_init_mount, state),
    do: {:noreply, send_internal_command(state, ":F3\r", :init_mount)}

  @impl true
  def handle_info(:save_home_position, state),
    do: {:noreply, send_internal_command(state, ":j1\r", :home_pos1)}

  @impl true
  def handle_info(:save_home_position_axis2, state),
    do: {:noreply, send_internal_command(state, ":j2\r", :home_pos2)}

  @impl true
  def handle_info(:return_home_after_reconnect, state) do
    Logger.info("Returning HOME after reconnect...")
    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
    Circuits.UART.write(state.uart_pid, ":L3\r")
    Process.sleep(300)
    send_goto_home_uart(state.uart_pid, state.home_position.axis1, "1")
    send_goto_home_uart(state.uart_pid, state.home_position.axis2, "2")
    {:noreply, %{state | dec_correction_ref: nil}}
  end

  @impl true
  def handle_info(:restore_activity, state) do
    case state.active_activity do
      {:tracking, cpr, tmr_freq} ->
        Logger.info("Restoring solar tracking after reconnect (CPR=#{cpr}, TMR=#{tmr_freq})")
        Task.start(fn -> start_solar_tracking(cpr, tmr_freq) end)
      nil ->
        Logger.debug("No activity to restore")
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(:correct_dec, state) do
    result =
      with {:ok, sun} <- do_calculate_sun_position(state),
           {:ok, cpr}  <- resolve_or_fetch(:cpr, state.last_cpr),
           {:ok, pos2} <- get_position("2") do
        target = Pointing.calculate_dec_steps(sun, cpr)
        delta  = target - pos2

        if abs(delta) > 100 do
          Logger.info("Dec correction: pos=#{pos2} → target=#{target} (delta=#{delta})")
          instant_stop("1")
          Process.sleep(300)
          do_goto_safe("2", target)
          wait_for_stop("2", 30_000)
          instant_stop("2")
          Process.sleep(300)
          start_solar_tracking(cpr, state.last_tmr_freq)
        else
          Logger.debug("Dec correction skipped, delta=#{delta} < 100")
        end
        :ok
      end

    if result != :ok, do: Logger.warning("Dec correction failed: #{inspect(result)}")
    ref = Process.send_after(self(), :correct_dec, @dec_correction_interval)
    {:noreply, %{state | dec_correction_ref: ref}}
  end

  @impl true
  def handle_info(:check_connection, state) do
    if state.connection_monitor_ref, do: Process.cancel_timer(state.connection_monitor_ref)

    new_state =
      cond do
        state.current_request != nil ->
          Logger.debug("Connection check skipped — command in progress")
          state

        not state.mount_initialized ->
          Logger.debug("Skipping ping — mount not yet initialized")
          state

        true ->
          case Circuits.UART.write(state.uart_pid, @ping_command) do
            :ok ->
              Process.send_after(self(), {:command_timeout, :connection_check}, 3_000)
              %{state | current_request: {:connection_check, @ping_command, 3_000}, response_buffer: ""}
            {:error, reason} ->
              Logger.error("Ping write failed: #{inspect(reason)}")
              reconnect(state)
          end
      end

    ref = schedule_connection_check(state.connection_check_interval)
    {:noreply, %{new_state | connection_monitor_ref: ref}}
  end

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
        {:noreply, process_next_command(%{new_state | current_request: nil, response_buffer: ""})}
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) do
    Logger.debug("← #{inspect(data)}")
    {:noreply, handle_response_data(state, data)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("UART process down: #{inspect(reason)}")
    {:noreply, reconnect(state)}
  end

  def handle_info({:EXIT, _ref, :normal}, state) do
    {:noreply, reconnect(state)}
  end

  def handle_info(:check_active_mount, state) do
    new_state = check_and_update_active_mount(state)
    schedule_mount_check()
    {:noreply, new_state}
  end

  # ===========================================================================
  # Private: UART / очередь
  # ===========================================================================

  defp send_command(command, timeout),
    do: GenServer.call(__MODULE__, {:send_command, command, timeout}, timeout * 2)

  defp send_internal_command(state, command, tag) do
    case Circuits.UART.write(state.uart_pid, command) do
      :ok ->
        Process.send_after(self(), {:command_timeout, tag}, @response_timeout)
        %{state | current_request: {tag, command, @response_timeout}, response_buffer: ""}
      {:error, reason} ->
        Logger.error("Failed to send internal command #{tag}: #{inspect(reason)}")
        state
    end
  end

  defp execute_command(%{connected: false} = state, from, _command, _timeout) do
    GenServer.reply(from, {:error, :not_connected})
    state
  end

  defp execute_command(state, from, command, timeout) do
    Logger.debug("→ #{inspect(command)}")
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

  defp handle_response_data(%{current_request: nil} = state, data) do
    case Protocol.parse_complete(data) do
      {:complete, response, _} ->
        case Protocol.parse_response(response) do
          {:ok, _} ->
            Logger.debug("Late response received — connection alive, resetting timeout counter")
            %{state | consecutive_timeouts: 0}
          _ ->
            Logger.warning("Late unexpected data: #{inspect(data)}")
            state
        end
      _ ->
        Logger.warning("Data received without pending request: #{inspect(data)}")
        state
    end
  end

  defp handle_response_data(%{current_request: {from, cmd, _}} = state, data) do
    case Protocol.parse_complete(state.response_buffer <> data) do
      {:complete, response, rest} ->
        Logger.debug("✓ #{inspect(response)}")
        result    = Protocol.parse_response(response)
        new_state = handle_command_result(state, from, cmd, result)
        process_next_command(%{new_state | current_request: nil, response_buffer: rest})
      {:incomplete, buffer} ->
        %{state | response_buffer: buffer}
    end
  end

  defp handle_command_result(state, :connection_check, _cmd, {:ok, _}) do
    %{state | consecutive_timeouts: 0, last_successful_command: %{command: :ping, timestamp: DateTime.utc_now()}}
  end

  defp handle_command_result(state, :connection_check, _cmd, {:error, reason}) do
    Logger.warning("Ping error: #{inspect(reason)}")
    handle_ping_timeout(state)
  end

  defp handle_command_result(state, :init_mount, _cmd, {:ok, _}) do
    Logger.info("✓ Mount initialized — starting connection monitoring")
    if state.connection_monitor_ref, do: Process.cancel_timer(state.connection_monitor_ref)
    ref = schedule_connection_check(state.connection_check_interval)
    state = %{state | mount_initialized: true, connection_monitor_ref: ref, status: :connected}

    if state.active_mount_id do
      Task.start(fn ->
        mount = SolarObservations.Repo.get(SolarObservations.Mount, state.active_mount_id)
        if mount do
          SolarObservations.Mount.changeset(mount, %{initialized: true})
          |> SolarObservations.Repo.update()
        end
      end)
    end

    cond do
      state.return_home_pending ->
        send(self(), :return_home_after_reconnect)
        %{state | return_home_pending: false}
      state.active_activity != nil ->
        Logger.info("Restoring activity after reconnect: #{inspect(state.active_activity)}")
        send(self(), :restore_activity)
        state
      true ->
        send(self(), :save_home_position)
        state
    end
  end

  defp handle_command_result(state, :init_mount, _cmd, {:error, reason}) do
    Logger.error("Init failed: #{inspect(reason)}, will retry on next connection check")
    %{state | mount_initialized: false}
  end

  defp handle_command_result(state, :home_pos1, _cmd, {:ok, raw}) do
    pos1 = Protocol.decode_position(raw)
    Logger.info("Home axis1 = #{pos1} steps")
    send(self(), :save_home_position_axis2)
    %{state | home_position: %{state.home_position | axis1: pos1}}
  end

  defp handle_command_result(state, :home_pos1, _cmd, {:error, reason}) do
    Logger.warning("home_pos1 error: #{inspect(reason)}")
    state
  end

  defp handle_command_result(state, :home_pos2, _cmd, {:ok, raw}) do
    pos2 = Protocol.decode_position(raw)
    Logger.info("✓ HOME saved: axis1=#{state.home_position.axis1}, axis2=#{pos2}")
    %{state | home_position: %{state.home_position | axis2: pos2}}
  end

  defp handle_command_result(state, :home_pos2, _cmd, {:error, reason}) do
    Logger.warning("home_pos2 error: #{inspect(reason)}")
    state
  end

  defp handle_command_result(state, from, cmd, result) do
    GenServer.reply(from, result)
    case result do
      {:ok, _} -> %{state | consecutive_timeouts: 0, last_successful_command: %{command: cmd, timestamp: DateTime.utc_now()}}
      _        -> state
    end
  end

  defp handle_ping_timeout(state) do
    timeouts = state.consecutive_timeouts + 1
    if timeouts >= state.max_consecutive_timeouts do
      Logger.error("CONNECTION LOST — reconnecting...")
      reconnect(state)
    else
      Logger.warning("Ping timeout #{timeouts}/#{state.max_consecutive_timeouts}")
      %{state | consecutive_timeouts: timeouts}
    end
  end

  defp reconnect(state) do
    if state.current_request do
      {from, _, _} = state.current_request
      unless from in [:connection_check, :init_mount, :home_pos1, :home_pos2],
        do: GenServer.reply(from, {:error, :connection_lost})
    end
    Enum.each(state.request_queue, fn {from, _, _} ->
      GenServer.reply(from, {:error, :connection_lost})
    end)
    if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
    Circuits.UART.close(state.uart_pid)
    schedule_reconnect(state.reconnect_interval)
    %{state |
      connected: false, current_request: nil, request_queue: [], response_buffer: "",
      consecutive_timeouts: 0, dec_correction_ref: nil, return_home_pending: true,
      mount_initialized: false
      # active_activity намеренно НЕ сбрасывается — восстанавливается после reconnect
    }
  end

  defp process_next_command(%{request_queue: []} = state), do: state
  defp process_next_command(%{request_queue: [{from, cmd, timeout} | rest]} = state),
    do: execute_command(%{state | request_queue: rest}, from, cmd, timeout)

  defp schedule_reconnect(interval),        do: Process.send_after(self(), :connect, interval)
  defp schedule_connection_check(interval), do: Process.send_after(self(), :check_connection, interval)

  defp send_goto_home_uart(uart_pid, current_steps, channel) do
    direction = if current_steps >= 0, do: "0", else: "1"
    Circuits.UART.write(uart_pid, ":G#{channel}0#{direction}\r"); Process.sleep(100)
    Circuits.UART.write(uart_pid, ":S#{channel}#{Protocol.encode_position(0)}\r"); Process.sleep(100)
    Circuits.UART.write(uart_pid, ":J#{channel}\r"); Process.sleep(100)
  end

  # ===========================================================================
  # Private: наводка
  # ===========================================================================

  defp do_goto_sun(timeout) do
    # TODO: проверить логи чтобы мы получали активнуб монтировку
    # И тестит наведение поле этого
    with {:ok, active_mount} <- get_active_mount(),
         {:ok, _sun} <- get_sun_position(),
         {:ok, cpr}  <- get_cpr("1"),
         {:ok, tmr}  <- get_timer_freq(),
         :ok         <- instant_stop("3"),
         _           <- Process.sleep(300),
         :ok         <- do_goto_safe("1", 0),
         :ok         <- do_goto_safe("2", 0),
         :ok         <- wait_for_stop("1", 60_000),
         :ok         <- wait_for_stop("2", 60_000),
         :ok         <- instant_stop("3"),
         _           <- Process.sleep(500),
         {:ok, sun2} <- get_sun_position() do
      IO.inspect(active_mount)

      lon = Decimal.to_float(active_mount.longitude)
      lst = Pointing.calculate_lst(DateTime.utc_now(), lon)
      IO.inspect("----------------------------------")

      IO.inspect(lon)
      IO.inspect(lst)

      {:ok, {axis1_steps, axis2_steps}} = Pointing.calculate_goto_steps(sun2, lst, cpr)
      chunk_steps = round(@chunk_degrees * cpr / 360.0)

      Logger.info("""
      ┌─ Pointing to Sun ────────────────────
      │  LST        : #{Float.round(lst, 4)}°
      │  RA         : #{Float.round(sun2.ra, 4)}°
      │  Dec        : #{Float.round(sun2.dec, 4)}°
      │  Alt        : #{Float.round(sun2.altitude, 2)}°
      │  axis1 steps: #{axis1_steps} (#{Pointing.direction_label(axis1_steps)})
      │  axis2 steps: #{axis2_steps} (#{Pointing.direction_label(axis2_steps)})
      │  chunk size : #{chunk_steps} steps (#{@chunk_degrees}°)
      └──────────────────────────────────────
      """)

      with :ok <- do_goto_chunked_and_wait(channel: "1", target: axis1_steps,
                                          cpr: cpr, chunk_steps: chunk_steps,
                                          timeout: timeout),
          :ok <- do_goto_chunked_and_wait(channel: "2", target: axis2_steps,
                                          cpr: cpr, chunk_steps: chunk_steps,
                                          timeout: timeout),
          :ok <- instant_stop("3"),
          _   <- Process.sleep(300) do
        Logger.info("✓ GOTO Sun complete — starting tracking")
        start_solar_tracking(cpr, tmr)
      end
    end
  end

  # Выполняет chunked GOTO от текущей позиции до target_steps,
  # затем ждёт полной остановки через wait_for_stop.
  # Используется в do_goto_sun где target — абсолютная позиция от HOME=0.
  defp do_goto_chunked_and_wait(channel: channel, target: target_steps,
                                 cpr: cpr, chunk_steps: chunk_steps, timeout: timeout) do
    with {:ok, curr_pos} <- get_position(channel) do
      remaining = target_steps - curr_pos
      Logger.info("[goto_sun] ch#{channel}: curr=#{curr_pos} → target=#{target_steps} (#{remaining} steps, #{Float.round(remaining * 360.0 / cpr, 2)}°)")
      result = do_goto_chunked(channel, curr_pos, remaining, cpr, chunk_steps, 1)
      case result do
        {:ok, _final} -> wait_for_stop(channel, timeout)
        error         -> error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Универсальный chunked GOTO
  #
  # abs_pos     — текущая абсолютная позиция контроллера (накапливается)
  # remaining   — сколько шагов ещё нужно пройти (со знаком)
  # chunk_steps — максимальный размер одного GOTO (≤ 24-bit лимита)
  #
  # Ось едет непрерывно: следующий чанк стартует сразу после остановки
  # предыдущего, без instant_stop и sleep между ними.
  # ---------------------------------------------------------------------------
  defp do_goto_chunked(_channel, abs_pos, 0, _cpr, _chunk_steps, _chunk_num),
    do: {:ok, abs_pos}

  defp do_goto_chunked(channel, abs_pos, remaining, cpr, chunk_steps, chunk_num) do
    sign      = if remaining >= 0, do: 1, else: -1
    chunk     = sign * min(abs(remaining), chunk_steps)
    target    = abs_pos + chunk
    chunk_deg = Float.round(chunk * 360.0 / cpr, 2)

    Logger.info("[chunk #{chunk_num}] ch#{channel} #{chunk_deg}° → abs=#{target} | left=#{Float.round((remaining - chunk) * 360.0 / cpr, 2)}°")

    direction = Pointing.direction_db2(chunk)
    with :ok <- set_motion_mode(channel, 0x0, direction),
         :ok <- set_goto_target(channel, target),
         :ok <- start_motion(channel),
         :ok <- wait_until_done(channel) do
      Logger.info("[chunk #{chunk_num}] ✓ arrived at #{target}")
      do_goto_chunked(channel, target, remaining - chunk, cpr, chunk_steps, chunk_num + 1)
    else
      error ->
        Logger.error("[chunk #{chunk_num}] FAILED: #{inspect(error)}")
        error
    end
  end

  # Простой GOTO без чанков — только для небольших смещений где переполнение невозможно
  # (используется в Dec-коррекции и stop_and_return_home через do_goto_safe).
  def do_goto(channel, target_steps) do
    with :ok <- set_motion_mode(channel, 0x0, Pointing.direction_db2(target_steps)),
         :ok <- set_goto_target(channel, target_steps),
         :ok <- start_motion(channel) do
      Logger.debug("GOTO ch#{channel} → #{target_steps} (#{Pointing.direction_label(target_steps)})")
      :ok
    end
  end

  # Безопасный GOTO с автоматическим chunked-разбиением.
  # Использовать везде где target может быть большим (HOME, goto_sun).
  def do_goto_safe(channel, target_steps) do
    with {:ok, cpr}      <- get_cpr("1"),
         {:ok, curr_pos} <- get_position(channel) do
      remaining   = target_steps - curr_pos
      chunk_steps = round(@chunk_degrees * cpr / 360.0)
      case do_goto_chunked(channel, curr_pos, remaining, cpr, chunk_steps, 1) do
        {:ok, _} -> :ok
        error    -> error
      end
    end
  end

  # ===========================================================================
  # Private: работа с активной монтировкой
  # ===========================================================================

  defp schedule_mount_check do
    Process.send_after(self(), :check_active_mount, @mount_check_interval)
  end

  defp check_and_update_active_mount(state) do
    # ИСПРАВЛЕННЫЙ СИНТАКСИС from
    active_mount = Repo.get_by(Mount, active: true)
      cond do
      is_nil(active_mount) and state.active_mount_id == nil ->
        Logger.debug("No active mount found, waiting...")
        state

      is_nil(active_mount) and state.active_mount_id != nil ->
        Logger.warning("Active mount removed, disconnecting...")
        disconnect(state)

      not is_nil(active_mount) and state.active_mount_id == nil ->
        Logger.info("Active mount found: #{active_mount.name}")
        mount_state = %{state | active_mount_id: active_mount.id,
                                 port_name: active_mount.port,
                                 baud_rate: active_mount.baud_rate,
                                 latitude: active_mount.latitude,
                                 longitude: active_mount.longitude,
                                 status: :connecting}
        send(self(), :connect)
        mount_state

      not is_nil(active_mount) and state.active_mount_id == active_mount.id ->
        if state.port_name != active_mount.port or
           state.baud_rate != active_mount.baud_rate or
           state.latitude != active_mount.latitude or
           state.longitude != active_mount.longitude do
          Logger.info("Active mount changed: #{active_mount.name}, reconnecting...")
          state = disconnect(state)
          %{state | active_mount_id: active_mount.id,
                    port_name: active_mount.port,
                    baud_rate: active_mount.baud_rate,
                    latitude: active_mount.latitude,
                    longitude: active_mount.longitude,
                    status: :connecting}
          |> then(fn s -> send(self(), :connect); s end)
        else
          state
        end

      true ->
        Logger.info("Switching active mount to #{active_mount.name}")
        state = disconnect(state)
        %{state | active_mount_id: active_mount.id,
                  port_name: active_mount.port,
                  baud_rate: active_mount.baud_rate,
                  latitude: active_mount.latitude,
                  longitude: active_mount.longitude,
                  status: :connecting}
        |> then(fn s -> send(self(), :connect); s end)
    end
  end

  defp disconnect(state) do
    if state.connected do
      if state.dec_correction_ref, do: Process.cancel_timer(state.dec_correction_ref)
      Circuits.UART.close(state.uart_pid)
      Logger.info("Disconnected from mount")
    end
    %{state | connected: false, mount_initialized: false, status: :waiting_for_mount,
               return_home_pending: true, current_request: nil, request_queue: [],
               response_buffer: "", consecutive_timeouts: 0, dec_correction_ref: nil}
  end

  defp do_calculate_sun_position(state) do
    case {state.latitude, state.longitude} do
      {lat, lon} when not is_nil(lat) and not is_nil(lon) ->
        now = DateTime.utc_now()
        lat_float = Decimal.to_float(lat)
        lon_float = Decimal.to_float(lon)
        {:ok, Pointing.calculate_sun_position(now, lat_float, lon_float)}
      _ ->
        {:error, :mount_not_ready}
    end
  end

  # ---------------------------------------------------------------------------
  # Ожидание остановки
  # ---------------------------------------------------------------------------

  # Ждёт стабилизации позиции — используется внутри do_goto_chunked
  # (нет таймаута, контроллер сам остановится на цели).
  defp wait_until_done(channel, poll_ms \\ 200) do
    do_wait_until_done(channel, poll_ms, System.monotonic_time(:millisecond), nil, 0)
  end

  defp do_wait_until_done(channel, poll_ms, started_at, last_pos, stable_count) do
    Process.sleep(poll_ms)
    with {:ok, pos} <- get_position(channel) do
      elapsed    = System.monotonic_time(:millisecond) - started_at
      new_stable = if pos == last_pos, do: stable_count + 1, else: 0

      Logger.debug("[wait] ch#{channel} pos=#{pos} stable=#{new_stable}/#{@stable_ticks_required} #{elapsed}ms")

      if new_stable >= @stable_ticks_required do
        Logger.info("[wait] ch#{channel} ✓ stable at #{pos} (#{elapsed}ms)")
        :ok
      else
        do_wait_until_done(channel, poll_ms, started_at, pos, new_stable)
      end
    end
  end

  # Ждёт завершения GOTO с дедлайном — используется после do_goto_chunked_and_wait
  # и в stop_and_return_home как страховка от зависания.
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
        {:ok, ^last_pos} when stable_count >= 2 ->
          Logger.debug("Axis #{channel} stable at #{last_pos} ✓")
          :ok
        {:ok, ^last_pos} ->
          Process.sleep(300)
          do_wait_for_stop(channel, deadline, last_pos, stable_count + 1)
        {:ok, pos} ->
          Process.sleep(300)
          do_wait_for_stop(channel, deadline, pos, 0)
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_axis_stopped(channel) do
    case get_status(channel) do
      {:ok, %{running: true}}  -> with(:ok <- instant_stop(channel), do: (Process.sleep(300); :ok))
      {:ok, %{running: false}} -> :ok
      {:error, reason}         -> {:error, reason}
    end
  end

  defp resolve_or_fetch(:cpr, nil),      do: get_cpr("1")
  defp resolve_or_fetch(:cpr, val),      do: {:ok, val}
  defp resolve_or_fetch(:tmr_freq, nil), do: get_timer_freq()
  defp resolve_or_fetch(:tmr_freq, val), do: {:ok, val}
end
