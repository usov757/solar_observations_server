defmodule SolarObservations.Astronomy.SolarTracker do
  @moduledoc """
  Модуль для автоматического слежения за Солнцем с экваториальной монтировкой.

  ОСНОВНЫЕ ИСПРАВЛЕНИЯ:
  1. Правильный расчёт T1_Preset по формулам из документации SkyWatcher
  2. Учёт высокоскоростного режима (High Speed Ratio)
  3. Корректное преобразование скорости в step_period
  """

  require Logger

  alias SolarObservations.Astronomy.{SolarCalculator, MountCoordinates}
  alias SolarObservations.Workers.MountWorker

  @default_tube_offset 90.0
  @home_position %{axis1: 0, axis2: 0}
  @solar_speed_deg_per_hour 15.041  # Солнечная скорость: 15.041°/час

  @doc """
  Основная функция для запуска слежения за Солнцем.
  """
  def start_tracking(opts \\ []) do
    latitude = Keyword.get(opts, :latitude) ||
               Application.get_env(:solar_observations, :observer_latitude)
    longitude = Keyword.get(opts, :longitude) ||
                Application.get_env(:solar_observations, :observer_longitude)

    tube_offset = Keyword.get(opts, :tube_offset, @default_tube_offset)

    cond do
      is_nil(latitude) or is_nil(longitude) ->
        Logger.error("Missing coordinates in config")
        {:error, :missing_coordinates}

      true ->
        Logger.info("""
        Starting solar tracking:
          Location: #{latitude}°, #{longitude}°
          Time: #{DateTime.to_string(DateTime.utc_now())}
          Solar speed: #{@solar_speed_deg_per_hour}°/hour
        """)

        # 1. Проверяем соединение
        case check_connection() do
          {:ok, position} ->
            Logger.info("✓ Mount connected. Position: #{inspect(position)}")

            # 2. Получаем параметры монтировки
            case MountCoordinates.initialize_mount_params() do
              {:ok, mount_params} ->
                mount_config = %{
                  mount_params: mount_params,
                  tube_offset: tube_offset,
                  home_position: @home_position
                }

                # 3. Останавливаем все моторы и сбрасываем состояние
                Logger.info("Stopping and resetting motors...")
                stop_and_reset_motors()

                # 4. Рассчитываем позицию Солнца
                Logger.info("Calculating sun position...")
                now = DateTime.utc_now()

                case SolarCalculator.calculate_simple_sun_position(latitude, longitude, now) do
                  {:ok, sun_pos} ->
                    Logger.info("""
                    Sun position:
                      RA: #{sun_pos.ra}h
                      Dec: #{sun_pos.dec}°
                    """)

                    # 5. Наводимся на Солнце (GOTO)
                    case goto_to_sun(sun_pos, mount_config) do
                      {:ok, _} ->
                        # 6. Запускаем слежение
                        case start_solar_tracking(mount_config) do
                          {:ok, _} ->
                            tracking_info = %{
                              latitude: latitude,
                              longitude: longitude,
                              tracking_started_at: now,
                              mount_config: mount_config,
                              sun_position: sun_pos
                            }

                            Logger.info("✓ Solar tracking started successfully!")
                            {:ok, tracking_info}

                          error ->
                            Logger.error("Failed to start tracking: #{inspect(error)}")
                            error
                        end

                      error ->
                        Logger.error("GOTO failed: #{inspect(error)}")
                        error
                    end

                  error ->
                    Logger.error("Failed to calculate sun position: #{inspect(error)}")
                    error
                end

              error ->
                Logger.error("Failed to get mount params: #{inspect(error)}")
                error
            end

          error ->
            Logger.error("Connection error: #{inspect(error)}")
            error
        end
    end
  end

  @doc """
  Проверяет соединение с монтировкой.
  """
  def check_connection do
    Logger.info("Checking mount connection...")

    with {:ok, pos1} <- MountWorker.get_position("1", 5000),
         {:ok, pos2} <- MountWorker.get_position("2", 5000) do

      Logger.info("✓ Mount is responding. Position: Axis1=#{pos1}, Axis2=#{pos2}")
      {:ok, %{axis1: pos1, axis2: pos2}}
    else
      {:error, :timeout} ->
        Logger.error("Mount not responding")
        {:error, :mount_not_responding}
      error ->
        Logger.error("Connection error: #{inspect(error)}")
        error
    end
  end

  @doc """
  Останавливает и сбрасывает все моторы в начальное состояние.
  """
  def stop_and_reset_motors do
    Logger.info("Stopping and resetting all motors...")

    # 1. Instant stop всех каналов
    Enum.each(["1", "2", "3"], &MountWorker.instant_stop/1)
    Process.sleep(1000)

    # 2. Регулярный stop
    Enum.each(["1", "2", "3"], &MountWorker.stop_motion/1)
    Process.sleep(1000)

    # 3. Устанавливаем GOTO режим (это сбрасывает tracking режим)
    Enum.each(["1", "2"], fn channel ->
      MountWorker.set_motion_mode(channel, 0x00, 5000)
    end)

    Process.sleep(1000)

    # 4. Инициализируем
    MountWorker.initialize("3", 5000)

    Logger.info("✓ Motors stopped and reset")
    :ok
  end

  @doc """
  Наводит монтировку на Солнце (GOTO).
  """
  def goto_to_sun(sun_pos, mount_config) do
    Logger.info("GOTO to sun position...")

    # Преобразуем RA/Dec в шаги
    case MountCoordinates.radec_to_steps(
      sun_pos.ra,
      sun_pos.dec,
      mount_config.mount_params,
      mount_config.tube_offset
    ) do
      {:ok, target_steps} ->
        Logger.info("""
        Target steps:
          Axis1 (RA): #{target_steps.axis1_steps} steps
          Axis2 (Dec): #{target_steps.axis2_steps} steps
        """)

        timeout = 15000

        # Устанавливаем GOTO режим
        with :ok <- MountWorker.set_motion_mode("1", 0x00, timeout),
             :ok <- MountWorker.set_motion_mode("2", 0x00, timeout),
             :ok <- MountWorker.set_goto_target("1", target_steps.axis1_steps, timeout),
             :ok <- MountWorker.set_goto_target("2", target_steps.axis2_steps, timeout),
             :ok <- MountWorker.start_motion("3", timeout) do

          Logger.info("Moving to target... (waiting 15 seconds)")
          Process.sleep(15000)

          # Останавливаем
          MountWorker.stop_motion("3")
          Process.sleep(2000)

          Logger.info("✓ GOTO completed")
          {:ok, :goto_complete}
        end

      error ->
        Logger.error("Failed to calculate target steps: #{inspect(error)}")
        error
    end
  end

  @doc """
  Запускает солнечное слежение.
  """
  def start_solar_tracking(mount_config) do
    Logger.info("Starting solar tracking...")

    mount_params = mount_config.mount_params
    timeout = 15000

    # 1. Останавливаем моторы
    stop_and_reset_motors()
    Process.sleep(2000)

    # 2. Рассчитываем солнечную скорость в градусах/сек
    solar_speed_deg_per_sec = @solar_speed_deg_per_hour / 3600.0
    Logger.info("Solar speed: #{solar_speed_deg_per_sec}°/sec")

    # 3. Рассчитываем T1_Preset для оси RA
    case calculate_t1_preset(
      solar_speed_deg_per_sec,
      mount_params.axis1_cpr,
      mount_params.timer_freq,
      mount_params.high_speed_ratio
    ) do
      {:ok, t1_preset} ->
        Logger.info("Calculated T1_Preset for RA axis: #{t1_preset}")

        # 4. Для оси Dec - очень медленная скорость (коррекция)
        dec_speed_deg_per_sec = solar_speed_deg_per_sec / 1000.0  # В 1000 раз медленнее

        case calculate_t1_preset(
          dec_speed_deg_per_sec,
          mount_params.axis2_cpr,
          mount_params.timer_freq,
          mount_params.high_speed_ratio
        ) do
          {:ok, t1_preset_dec} ->
            Logger.info("""
            Tracking parameters:
              RA: T1_Preset=#{t1_preset} (#{@solar_speed_deg_per_hour}°/hour)
              Dec: T1_Preset=#{t1_preset_dec} (#{dec_speed_deg_per_sec * 3600}°/hour)
            """)

            # 5. Устанавливаем tracking режим (0x03 = tracking CCW)
            Logger.info("Setting tracking mode...")

            with :ok <- MountWorker.set_motion_mode("1", 0x03, timeout),
                 :ok <- MountWorker.set_motion_mode("2", 0x03, timeout),
                 :ok <- MountWorker.set_step_period("1", t1_preset, timeout),
                 :ok <- MountWorker.set_step_period("2", t1_preset_dec, timeout) do

              # 6. Проверяем что режим установился
              Process.sleep(500)

              case verify_tracking_mode() do
                {:ok, true} ->
                  # 7. Запускаем движение
                  Logger.info("Starting motion...")

                  case MountWorker.start_motion("3", timeout) do
                    :ok ->
                      # 8. Проверяем что началось движение
                      Process.sleep(3000)

                      case verify_movement() do
                        {:ok, true} ->
                          Logger.info("✓✓✓ SOLAR TRACKING ACTIVE! ✓✓✓")
                          {:ok, :tracking_active}

                        {:ok, false} ->
                          Logger.warning("Motors not moving. Adjusting speed...")
                          # Пробуем скорректировать скорость
                          adjust_tracking_speed(mount_params, t1_preset, t1_preset_dec)

                        error ->
                          error
                      end

                    error ->
                      Logger.error("Failed to start motion: #{inspect(error)}")
                      error
                  end

                {:ok, false} ->
                  Logger.error("Tracking mode not set!")
                  {:error, :tracking_mode_not_set}

                error ->
                  error
              end
            else
              {:error, {:unknown_error, "2"}} ->
                Logger.error("Motor not stopped. Retrying...")
                Process.sleep(2000)
                start_solar_tracking(mount_config)

              error ->
                Logger.error("Failed to set tracking mode: #{inspect(error)}")
                error
            end

          error ->
            Logger.error("Failed to calculate Dec T1_Preset: #{inspect(error)}")
            error
        end

      error ->
        Logger.error("Failed to calculate RA T1_Preset: #{inspect(error)}")
        error
    end
  end

  @doc """
  Останавливает слежение.
  """
  def stop_tracking do
    Logger.info("Stopping solar tracking...")

    # 1. Останавливаем моторы
    Enum.each(["1", "2", "3"], &MountWorker.instant_stop/1)
    Process.sleep(1000)

    # 2. Сбрасываем в GOTO режим
    Enum.each(["1", "2"], fn channel ->
      MountWorker.set_motion_mode(channel, 0x00, 5000)
    end)

    Process.sleep(1000)

    Logger.info("✓ Tracking stopped")
    :ok
  end

  # ============================================================
  # КЛЮЧЕВЫЕ ИСПРАВЛЕНИЯ: Расчет T1_Preset
  # ============================================================

  @doc """
  Рассчитывает T1_Preset для заданной скорости.

  Формула из документации SkyWatcher:

  1. Для низкой скорости (без high-speed режима):
     T1_Preset = TMR_Freq * 360 / (Speed_DegPerSec * CPR)

  2. Для высокой скорости (с high-speed режимом):
     T1_Preset = N * TMR_Freq * 360 / (Speed_DegPerSec * CPR)

     где N = high_speed_ratio (обычно 16, 32 или 64)
  """
  def calculate_t1_preset(speed_deg_per_sec, cpr, timer_freq, high_speed_ratio \\ 1) do
    # Проверяем допустимость параметров
    cond do
      speed_deg_per_sec <= 0 ->
        {:error, :invalid_speed}
      cpr <= 0 ->
        {:error, :invalid_cpr}
      timer_freq <= 0 ->
        {:error, :invalid_timer_freq}
      true ->
        # Прямая формула из документации SkyWatcher
        # T1_Preset = N * TMR_Freq * 360 / (Speed_DegPerSec * CPR)
        t1_preset = trunc(high_speed_ratio * timer_freq * 360 / (speed_deg_per_sec * cpr))

        # Ограничиваем диапазон (должно быть не менее 6 по документации, максимум 24-битное значение)
        final_t1_preset = max(6, min(t1_preset, 16777215))

        # Логируем если используется high-speed режим
        if high_speed_ratio > 1 and t1_preset < 16777215 do
          Logger.info("Using high-speed mode (N=#{high_speed_ratio}), T1_Preset=#{final_t1_preset}")
        end

        {:ok, final_t1_preset}
    end
  end

  # ============================================================
  # ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
  # ============================================================

  defp verify_tracking_mode do
    Logger.debug("Verifying tracking mode...")

    with {:ok, status1} <- MountWorker.get_status("1"),
         {:ok, status2} <- MountWorker.get_status("2") do

      in_tracking_mode = status1.tracking_mode and status2.tracking_mode

      if in_tracking_mode do
        Logger.debug("✓ Motors in tracking mode")
      else
        Logger.debug("Motors not in tracking mode. Status1: #{inspect(status1)}, Status2: #{inspect(status2)}")
      end

      {:ok, in_tracking_mode}
    end
  end

  defp verify_movement do
    Logger.debug("Verifying movement...")

    # Проверяем изменение позиции за 2 секунды
    with {:ok, pos1_start} <- MountWorker.get_position("1"),
         {:ok, pos2_start} <- MountWorker.get_position("2"),
         Process.sleep(2000),
         {:ok, pos1_end} <- MountWorker.get_position("1"),
         {:ok, pos2_end} <- MountWorker.get_position("2") do

      delta1 = abs(pos1_end - pos1_start)
      delta2 = abs(pos2_end - pos2_start)

      moving = delta1 > 10 or delta2 > 10  # Порог 10 шагов

      if moving do
        Logger.debug("✓ Motors moving. Delta1: #{delta1}, Delta2: #{delta2}")
      else
        Logger.debug("Motors not moving. Delta1: #{delta1}, Delta2: #{delta2}")
      end

      {:ok, moving}
    end
  end

  defp adjust_tracking_speed(_mount_params, original_t1_preset, original_t1_preset_dec) do
    # Пробуем скорректировать T1_Preset (сделать меньше для большей скорости)
    adjusted_t1_preset = max(6, trunc(original_t1_preset * 0.8))  # На 20% быстрее
    adjusted_t1_preset_dec = max(6, trunc(original_t1_preset_dec * 0.8))

    Logger.info("""
    Adjusting tracking speed:
      RA: T1_Preset=#{adjusted_t1_preset} (was #{original_t1_preset})
      Dec: T1_Preset=#{adjusted_t1_preset_dec} (was #{original_t1_preset_dec})
    """)

    # Останавливаем
    stop_and_reset_motors()
    Process.sleep(2000)

    # Устанавливаем новую скорость
    with :ok <- MountWorker.set_motion_mode("1", 0x03, 10000),
         :ok <- MountWorker.set_motion_mode("2", 0x03, 10000),
         :ok <- MountWorker.set_step_period("1", adjusted_t1_preset, 10000),
         :ok <- MountWorker.set_step_period("2", adjusted_t1_preset_dec, 10000),
         :ok <- MountWorker.start_motion("3", 10000) do

      Process.sleep(3000)

      case verify_movement() do
        {:ok, true} ->
          Logger.info("✓ Tracking started with adjusted speed")
          {:ok, :tracking_active_adjusted}

        {:ok, false} ->
          # Пробуем еще быстрее
          even_faster_t1 = max(6, trunc(adjusted_t1_preset * 0.5))
          Logger.info("Still not moving. Trying T1_Preset=#{even_faster_t1}")

          MountWorker.set_step_period("1", even_faster_t1, 10000)
          Process.sleep(3000)

          case verify_movement() do
            {:ok, true} -> {:ok, :tracking_active_very_fast}
            _ -> {:error, :motors_not_moving}
          end

        error ->
          error
      end
    else
      error ->
        Logger.error("Failed to adjust speed: #{inspect(error)}")
        error
    end
  end

  @doc """
  Проверяет состояние моторов и возвращает диагностическую информацию.
  """
  def check_motor_status do
    Logger.info("Checking motor status...")

    with {:ok, status1} <- MountWorker.get_status("1"),
         {:ok, status2} <- MountWorker.get_status("2"),
         {:ok, pos1} <- MountWorker.get_position("1"),
         {:ok, pos2} <- MountWorker.get_position("2") do

      info = %{
        axis1: %{
          status: status1,
          position: pos1,
          mode: if(status1.tracking_mode, do: "TRACKING", else: "GOTO"),
          enabled: status1.running,
          blocked: status1.blocked
        },
        axis2: %{
          status: status2,
          position: pos2,
          mode: if(status2.tracking_mode, do: "TRACKING", else: "GOTO"),
          enabled: status2.running,
          blocked: status2.blocked
        }
      }

      Logger.info("""
      Motor Status:
        Axis1: #{info.axis1.mode}, Position: #{pos1}, Enabled: #{info.axis1.enabled}
        Axis2: #{info.axis2.mode}, Position: #{pos2}, Enabled: #{info.axis2.enabled}
      """)

      {:ok, info}
    end
  end

  @doc """
  Простой тест: запускает tracking на 30 секунд.
  """
  def test_tracking_30_seconds do
    Logger.info("=== TEST: Starting tracking for 30 seconds ===")

    case MountCoordinates.initialize_mount_params() do
      {:ok, mount_params} ->
        _mount_config = %{
          mount_params: mount_params,
          tube_offset: 90.0,
          home_position: @home_position
        }

        # Останавливаем и сбрасываем
        stop_and_reset_motors()
        Process.sleep(2000)

        # Запускаем tracking
        solar_speed = @solar_speed_deg_per_hour / 3600.0

        case calculate_t1_preset(
          solar_speed,
          mount_params.axis1_cpr,
          mount_params.timer_freq,
          mount_params.high_speed_ratio
        ) do
          {:ok, t1_preset} ->
            Logger.info("Calculated T1_Preset: #{t1_preset}")

            with :ok <- MountWorker.set_motion_mode("1", 0x03, 10000),
                 :ok <- MountWorker.set_step_period("1", t1_preset, 10000),
                 :ok <- MountWorker.start_motion("3", 10000) do

              Logger.info("Tracking started. T1_Preset: #{t1_preset}. Waiting 30 seconds...")

              # Мониторим 30 секунд
              for i <- 1..30 do
                Process.sleep(1000)
                if rem(i, 5) == 0 do
                  case MountWorker.get_position("1") do
                    {:ok, pos} ->
                      # Преобразуем шаги в градусы
                      degrees = pos / mount_params.axis1_cpr * 360.0
                      Logger.info("#{i}s: Position = #{pos} steps (#{degrees}°)")
                    _ -> Logger.info("#{i}s: Checking...")
                  end
                end
              end

              # Останавливаем
              stop_tracking()
              Logger.info("✓ Test completed")
              :ok

            else
              error ->
                Logger.error("Test failed: #{inspect(error)}")
                error
            end

          error ->
            Logger.error("Failed to calculate T1_Preset: #{inspect(error)}")
            error
        end

      error ->
        Logger.error("Failed to get mount params: #{inspect(error)}")
        error
    end
  end
end
