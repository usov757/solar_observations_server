defmodule SolarObservations.Workers.Camera.CameraWorker do
  @moduledoc """
  GenServer для управления ASI6200MM Pro через Erlang Port (asi_port).

  ## Слои

    * `CameraWorker`   — GenServer: публичный API, FSM, PubSub-broadcast.
    * `CameraCommands` — сборка бинарных команд (encode → binary для Port).
    * `CameraResponse` — разбор бинарных ответов (decode ← binary от Port).

  ## Протокол

  Связь с `asi_port` — stdin/stdout, `{:packet, 4}` (4-байтовый big-endian
  заголовок длины). Первый байт тела ответа:
    `0x00` — успех (далее опциональные данные)
    `0xFF` — ошибка (далее ASCII-строка причины)

  ## Машина состояний camera_state

    :disconnected → :connecting → :idle ⇄ :capturing
                                        ⇄ :streaming

  ## PubSub

  Кадры рассылаются в топик `"camera:frames"`:

      {:camera_frame, %{
        frame:     binary(),      # RAW16, width * height * 2 байт
        width:     integer(),
        height:    integer(),
        format:    :raw16,
        frame_num: integer(),
        timestamp: DateTime.t()
      }}
  """

  use GenServer
  require Logger
  import Bitwise


  alias SolarObservations.Workers.Camera.Utils.CameraCommands, as: Cmd
  alias SolarObservations.Workers.Camera.Utils.CameraResponse, as: Resp

  @poll_interval_ms 50

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]},
      shutdown: 10_000, type: :worker}
  end

  @doc """
  Сделать одиночный снимок.
  `exposure_us` — выдержка в мкс. Таймаут GenServer.call = exposure + 10 с.
  """
  @spec capture_frame(pos_integer(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def capture_frame(exposure_us \\ 1_000_000, gain \\ 0) do
    GenServer.call(__MODULE__, {:capture, exposure_us, gain}, div(exposure_us, 1_000) + 10_000)
  end

  @doc "Запустить непрерывный поток кадров → PubSub `\"camera:frames\"`."
  @spec start_stream(keyword()) :: :ok | {:error, term()}
  def start_stream(opts \\ []) do
    GenServer.call(__MODULE__, {:start_stream, opts})
  end

  @doc "Остановить непрерывный поток."
  @spec stop_stream() :: :ok | {:error, term()}
  def stop_stream, do: GenServer.call(__MODULE__, :stop_stream)

  @doc "Установить целевую температуру охладителя (°C)."
  @spec set_temperature(number()) :: :ok | {:error, term()}
  def set_temperature(celsius), do: GenServer.call(__MODULE__, {:set_cooler, celsius})

  @doc "Получить текущую температуру сенсора (°C)."
  @spec get_temperature() :: {:ok, float()} | {:error, term()}
  def get_temperature, do: GenServer.call(__MODULE__, :get_temp, 5_000)

  @doc "Статус воркера."
  @spec status() :: {:ok, map()}
  def status, do: GenServer.call(__MODULE__, :status)

  # ===========================================================================
  # Init
  # ===========================================================================

  @impl true
  def init(opts) do
    cfg = fn key, default ->
      :solar_observations
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(key, default)
    end

    port_path          = opts |> Keyword.get(:port_path,          cfg.(:port_path, "priv/port/asi_port")) |> Path.expand()
    reconnect_interval = opts |> Keyword.get(:reconnect_interval, cfg.(:reconnect_interval, 5_000))

    state = %{
      port:               nil,
      port_path:          port_path,
      reconnect_interval: reconnect_interval,

      # :disconnected | :connecting | :idle | :capturing | :streaming
      camera_state:  :disconnected,

      roi: %{
        width:    Cmd.default_width(),
        height:   Cmd.default_height(),
        bin:      Cmd.default_bin(),
        img_type: Cmd.asi_img_raw16()
      },

      stream_opts:   [],
      stream_timer:  nil,
      frames_sent:   0,
      last_frame_at: nil,

      # {from, :capture} | {from, :get_temp} | nil
      pending: nil,

      # причина недоступности камеры — для понятных сообщений об ошибке
      disconnected_reason: :initial
    }

    Logger.info("[CameraWorker] ══════════════════════════════════════════")
    Logger.info("[CameraWorker] Starting up")
    Logger.info("[CameraWorker]   port_path:          #{port_path}")
    Logger.info("[CameraWorker]   reconnect_interval: #{reconnect_interval}ms")
    Logger.info("[CameraWorker]   ROI: #{Cmd.default_width()}×#{Cmd.default_height()} bin=#{Cmd.default_bin()}")
    Logger.info("[CameraWorker] ══════════════════════════════════════════")

    send(self(), :connect)
    {:ok, state}
  end

  # ===========================================================================
  # handle_call
  # ===========================================================================

  @impl true
  def handle_call(msg, _from, %{camera_state: :disconnected} = state) do
    reason = Map.get(state, :disconnected_reason, :binary_not_found)
    {:reply, {:error, camera_unavailable_message(msg, reason)}, state}
  end

  def handle_call(msg, _from, %{camera_state: :connecting} = state) do
    {:reply, {:error, camera_unavailable_message(msg, :connecting)}, state}
  end

  # --- одиночный снимок ------------------------------------------------------

  def handle_call({:capture, _exp_us, _gain}, _from, %{camera_state: :streaming} = state),
    do: {:reply, {:error, :stream_active}, state}

  def handle_call({:capture, _exp_us, _gain}, _from, %{camera_state: :capturing} = state),
    do: {:reply, {:error, :capture_in_progress}, state}

  def handle_call({:capture, exp_us, gain}, from, %{camera_state: :idle} = state) do
    Logger.info("[CameraWorker] ▶ Capture requested — exp=#{exp_us}µs (#{Float.round(exp_us / 1_000.0, 1)}ms) gain=#{gain}")
    port_send(state.port, Cmd.set_exposure(exp_us))
    port_send(state.port, Cmd.set_gain(gain))
    port_send(state.port, Cmd.start_exposure())
    Logger.debug("[CameraWorker]   → set_exposure + set_gain + start_exposure sent to port")
    {:noreply, %{state | camera_state: :capturing,
                         pending:      {from, :capture},
                         stream_timer: schedule_poll()}}
  end

  # --- поток -----------------------------------------------------------------

  def handle_call({:start_stream, _opts}, _from, %{camera_state: :streaming} = state),
    do: {:reply, {:error, :already_streaming}, state}

  def handle_call({:start_stream, opts}, _from, %{camera_state: :idle} = state) do
    exp_us = Keyword.get(opts, :exposure_us, 1_000_000)
    gain   = Keyword.get(opts, :gain, 0)
    port_send(state.port, Cmd.set_exposure(exp_us))
    port_send(state.port, Cmd.set_gain(gain))
    port_send(state.port, Cmd.start_exposure())
    Logger.info("[CameraWorker] Stream started — exp=#{exp_us}µs gain=#{gain}")
    {:reply, :ok, %{state | camera_state: :streaming,
                             stream_opts:  opts,
                             stream_timer: schedule_poll()}}
  end

  def handle_call(:stop_stream, _from, %{camera_state: :streaming} = state) do
    cancel_timer(state.stream_timer)
    elapsed = if state.last_frame_at do
      DateTime.diff(DateTime.utc_now(), state.last_frame_at, :millisecond)
    end
    Logger.info("[CameraWorker] ⏹  Stream stopped — total frames: #{state.frames_sent}" <>
      if(elapsed, do: ", last frame #{elapsed}ms ago", else: ""))
    {:reply, :ok, %{state | camera_state: :idle, stream_timer: nil}}
  end

  def handle_call(:stop_stream, _from, state),
    do: {:reply, {:error, :not_streaming}, state}

  # --- охладитель ------------------------------------------------------------

  def handle_call({:set_cooler, celsius}, _from, state) do
    Logger.info("[CameraWorker] 🌡  Setting cooler target: #{celsius}°C")
    port_send(state.port, Cmd.set_cooler(celsius))
    {:reply, :ok, state}
  end

  # --- температура -----------------------------------------------------------

  def handle_call(:get_temp, _from, %{pending: p} = state) when not is_nil(p),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:get_temp, from, state) do
    port_send(state.port, Cmd.get_temperature())
    {:noreply, %{state | pending: {from, :get_temp}}}
  end

  # --- статус ----------------------------------------------------------------

  def handle_call(:status, _from, state) do
    status_map = %{
      camera_state:  state.camera_state,
      frames_sent:   state.frames_sent,
      last_frame_at: state.last_frame_at,
      roi:           state.roi,
      streaming:     state.camera_state == :streaming,
      capturing:     state.camera_state == :capturing,
      ready:         state.camera_state in [:idle, :capturing, :streaming]
    }

    status_map = if state.camera_state == :disconnected do
      Map.put(status_map, :disconnected_reason, state.disconnected_reason)
    else
      status_map
    end

    Logger.debug("[CameraWorker] Status requested: #{state.camera_state}")
    {:reply, {:ok, status_map}, state}
  end

  # ===========================================================================
  # handle_info — подключение
  # ===========================================================================

  @impl true
  def handle_info(:connect, state) do
    Logger.info("[CameraWorker] ┌─ Connecting to asi_port...")
    Logger.info("[CameraWorker] │  path: #{state.port_path}")

    cond do
      not File.exists?(state.port_path) ->
        Logger.warning("[CameraWorker] └─ ✗ Binary not found at #{state.port_path}")
        Logger.warning("[CameraWorker]    Fix: cd priv/port && make && chmod +x asi_port")
        Logger.warning("[CameraWorker]    Retrying in #{state.reconnect_interval}ms...")
        schedule_reconnect(state.reconnect_interval)
        {:noreply, %{state | disconnected_reason: :binary_not_found}}

      not executable?(state.port_path) ->
        Logger.warning("[CameraWorker] └─ ✗ Binary exists but is not executable")
        Logger.warning("[CameraWorker]    Fix: chmod +x #{state.port_path}")
        Logger.warning("[CameraWorker]    Retrying in #{state.reconnect_interval}ms...")
        schedule_reconnect(state.reconnect_interval)
        {:noreply, %{state | disconnected_reason: :not_executable}}

      true ->
        Logger.info("[CameraWorker] │  Binary found and executable ✓")
        Logger.info("[CameraWorker] │  Opening port (packet: 4, binary, exit_status)...")
        port = Port.open(
          {:spawn_executable, state.port_path},
          [{:packet, 4}, :binary, :exit_status]
        )
        Logger.info("[CameraWorker] │  Port opened: #{inspect(port)}")
        Logger.info("[CameraWorker] │  Sending open_camera command...")
        port_send(port, Cmd.open_camera())
        Logger.info("[CameraWorker] └─ Waiting for camera response...")
        {:noreply, %{state | port: port, camera_state: :connecting}}
    end
  end

  # ===========================================================================
  # handle_info — ответы от asi_port
  # ===========================================================================

  # --- Камера открылась ------------------------------------------------------

  @impl true
  def handle_info({port, {:data, data}}, %{camera_state: :connecting} = state)
      when state.port == port do
    IO.inspect(data, label: "camera_opened raw data")

    case Resp.camera_opened(data) do
      {:ok, cam_id} ->
        Logger.info("[CameraWorker] ┌─ Camera opened successfully ✓")
        Logger.info("[CameraWorker] │  cam_id: #{cam_id}")
        Logger.info("[CameraWorker] │  Sending set_roi command...")
        Logger.info("[CameraWorker] │  ROI: #{state.roi.width}×#{state.roi.height} bin=#{state.roi.bin} img_type=#{state.roi.img_type}")
        port_send(port, Cmd.set_roi())
        Logger.info("[CameraWorker] └─ Camera state: idle — ready for commands ✓")
        {:noreply, %{state | camera_state: :idle, disconnected_reason: nil}}

      {:error, reason} ->
        Logger.error("[CameraWorker] ┌─ Camera failed to open ✗")
        Logger.error("[CameraWorker] │  reason: #{inspect(reason)}")
        Logger.error("[CameraWorker] │  Check: USB connection, ASI drivers, camera power")
        Logger.error("[CameraWorker] └─ Retrying in #{state.reconnect_interval}ms...")
        schedule_reconnect(state.reconnect_interval)
        {:noreply, %{state | port: nil, camera_state: :disconnected,
                             disconnected_reason: {:open_failed, reason}}}
    end
  end

  # --- Polling: запрашиваем статус экспозиции --------------------------------

  def handle_info(:poll, state) do
    Logger.debug("[CameraWorker] ↻ Polling exposure status (state=#{state.camera_state})")
    port_send(state.port, Cmd.get_exp_status())
    {:noreply, state}
  end

  # --- Ответ на get_temperature ----------------------------------------------

  def handle_info({port, {:data, data}}, %{pending: {from, :get_temp}} = state)
      when state.port == port do
    result = Resp.temperature(data)
    case result do
      {:ok, temp} -> Logger.info("[CameraWorker] 🌡  Sensor temperature: #{temp}°C")
      {:error, r} -> Logger.warning("[CameraWorker] 🌡  Failed to read temperature: #{inspect(r)}")
    end
    GenServer.reply(from, result)
    {:noreply, %{state | pending: nil}}
  end

  # --- Ответ во время capture / stream — статус или кадр --------------------

  def handle_info({port, {:data, data}}, %{camera_state: cs} = state)
      when state.port == port and cs in [:capturing, :streaming] do
    handle_port_data(data, state)
  end

  # --- Простой :ok (от set_roi, set_cooler и т.д.) -------------------------

  def handle_info({port, {:data, data}}, state) when state.port == port do
    case Resp.ack(data) do
      :ok              -> :ok
      {:error, reason} -> Logger.warning("[CameraWorker] Unexpected error: #{reason}")
    end
    {:noreply, state}
  end

  # --- asi_port процесс упал ------------------------------------------------

  def handle_info({port, {:exit_status, code}}, state) when state.port == port do
    Logger.error("[CameraWorker] ┌─ asi_port process exited ✗")
    Logger.error("[CameraWorker] │  exit code: #{code}")
    Logger.error("[CameraWorker] │  camera state was: #{state.camera_state}")
    if state.pending do
      Logger.error("[CameraWorker] │  pending call aborted: #{inspect(elem(state.pending, 1))}")
      GenServer.reply(elem(state.pending, 0), {:error, :port_died})
    end
    Logger.error("[CameraWorker] └─ Reconnecting in #{state.reconnect_interval}ms...")
    cancel_timer(state.stream_timer)
    schedule_reconnect(state.reconnect_interval)
    {:noreply, %{state | port: nil, camera_state: :disconnected,
                         disconnected_reason: {:port_exited, code},
                         pending: nil, stream_timer: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("[CameraWorker] Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  # ===========================================================================
  # Private: маршрутизация данных от порта
  # ===========================================================================

  # Пытаемся разобрать как статус экспозиции — 2 байта (0x00 + status)
  defp handle_port_data(<<0x00, _status_byte>> = data, state) do
    case Resp.exp_status(data) do
      {:ok, :working} ->
        Logger.debug("[CameraWorker] ↻ Exposure in progress...")
        {:noreply, %{state | stream_timer: schedule_poll()}}

      {:ok, :idle} ->
        Logger.debug("[CameraWorker] ↻ Exposure idle")
        {:noreply, state}

      {:ok, :success} ->
        Logger.debug("[CameraWorker] ✓ Exposure complete — requesting frame")
        port_send(state.port, Cmd.get_frame())
        {:noreply, state}

      {:ok, :failed} ->
        handle_exp_failed(state)

      {:error, reason} ->
        Logger.error("[CameraWorker] exp_status parse error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Всё остальное с 0x00 и данными — это кадр
  defp handle_port_data(<<0x00, frame::binary>>, state) when byte_size(frame) > 0 do
    {:noreply, handle_frame(frame, state)}
  end

  # Ошибка от порта
  defp handle_port_data(<<0xFF, reason::binary>>, state) do
    Logger.error("[CameraWorker] asi_port error: #{reason}")
    case state.pending do
      {from, _} -> GenServer.reply(from, {:error, reason})
      nil       -> :ok
    end
    {:noreply, %{state | pending: nil, camera_state: :idle}}
  end

  defp handle_port_data(other, state) do
    Logger.warning("[CameraWorker] Unknown data: #{inspect(other)}")
    {:noreply, state}
  end

  # ===========================================================================
  # Private: обработка результатов экспозиции
  # ===========================================================================

  defp handle_exp_failed(%{camera_state: :capturing, pending: {from, :capture}} = state) do
    Logger.warning("[CameraWorker] ✗ Exposure failed (single capture) — returning error to caller")
    GenServer.reply(from, {:error, :exposure_failed})
    {:noreply, %{state | camera_state: :idle, pending: nil, stream_timer: nil}}
  end

  defp handle_exp_failed(%{camera_state: :streaming} = state) do
    Logger.warning("[CameraWorker] ✗ Exposure failed (stream) — retrying automatically")
    restart_stream_exposure(state)
  end

  defp restart_stream_exposure(state) do
    exp_us = Keyword.get(state.stream_opts, :exposure_us, 1_000_000)
    gain   = Keyword.get(state.stream_opts, :gain, 0)
    Logger.debug("[CameraWorker] ↺ Restarting stream exposure — exp=#{exp_us}µs gain=#{gain}")
    port_send(state.port, Cmd.set_exposure(exp_us))
    port_send(state.port, Cmd.set_gain(gain))
    port_send(state.port, Cmd.start_exposure())
    {:noreply, %{state | stream_timer: schedule_poll()}}
  end

  # ===========================================================================
  # Private: обработка кадра
  # ===========================================================================

  defp handle_frame(frame, %{camera_state: :capturing, pending: {from, :capture}} = state) do
    size_kb = Float.round(byte_size(frame) / 1024.0, 1)
    Logger.info("[CameraWorker] ✓ Frame captured — #{byte_size(frame)} bytes (#{size_kb} KB)")
    GenServer.reply(from, {:ok, frame})
    %{state | camera_state: :idle, pending: nil,
              stream_timer: nil, last_frame_at: DateTime.utc_now()}
  end

  defp handle_frame(frame, %{camera_state: :streaming} = state) do
    size_kb  = Float.round(byte_size(frame) / 1024.0, 1)
    frame_n  = state.frames_sent + 1
    Logger.debug("[CameraWorker] 📷 Stream frame ##{frame_n} — #{size_kb} KB")
    if rem(frame_n, 100) == 0 do
      Logger.info("[CameraWorker] 📷 Stream milestone: #{frame_n} frames sent")
    end
    broadcast_frame(frame, state)
    updated = %{state | frames_sent: frame_n, last_frame_at: DateTime.utc_now()}
    {:noreply, result} = restart_stream_exposure(updated)
    result
  end

  # ===========================================================================
  # Private: утилиты
  # ===========================================================================

  @spec port_send(port(), binary()) :: true
  defp port_send(port, cmd), do: Port.command(port, cmd)

  @spec schedule_poll() :: reference()
  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  # ИСПРАВЛЕНИЕ: было `do: Process.cancel_timer(ref); :ok` —
  # точка с запятой внутри однострочного do: не образует блок,
  # второе выражение (:ok) становится телом самого defp, не частью функции.
  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  @spec schedule_reconnect(pos_integer()) :: reference()
  defp schedule_reconnect(ms), do: Process.send_after(self(), :connect, ms)

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # Формирует человекочитаемое сообщение об ошибке в зависимости от того,
  # какую команду пытались выполнить и почему камера недоступна.
  defp camera_unavailable_message(msg, reason) do
    action = case msg do
      {:capture, _, _}    -> "make a capture"
      {:start_stream, _}  -> "start stream"
      :stop_stream        -> "stop stream"
      {:set_cooler, _}    -> "set cooler temperature"
      :get_temp           -> "read temperature"
      :status             -> "get status"
      _                   -> "execute camera command"
    end

    explanation = case reason do
      :initial ->
        "Camera worker is starting up, please retry in a moment."

      :connecting ->
        "Camera is connecting, please retry in a moment."

      :not_executable ->
        "The asi_port binary exists but is not executable. " <>
        "Fix: run `chmod +x priv/port/asi_port` in the project root."

      :binary_not_found ->
        "The asi_port driver binary was not found. " <>
        "Please compile it by running `make` inside priv/port/. " <>
        "The camera will reconnect automatically once the binary is available."

      {:open_failed, detail} ->
        "Camera opened the port but failed to initialise: #{detail}. " <>
        "Check that the ASI camera is plugged in via USB."

      {:port_exited, code} ->
        "The asi_port driver process exited unexpectedly (exit code #{code}). " <>
        "Check USB connection and driver logs."

      other ->
        "Camera unavailable (#{inspect(other)})."
    end

    %{
      error:   :camera_unavailable,
      action:  action,
      message: "Cannot #{action}: #{explanation}"
    }
  end

  @spec broadcast_frame(binary(), map()) :: :ok | {:error, term()}
  defp broadcast_frame(frame, state) do
    Phoenix.PubSub.broadcast(
      SolarObservations.PubSub,
      "camera:frames",
      {:camera_frame, %{
        frame:     frame,
        width:     state.roi.width,
        height:    state.roi.height,
        format:    :raw16,
        frame_num: state.frames_sent,
        timestamp: DateTime.utc_now()
      }}
    )
  end
end
