# 1. Пинг
SolarObservations.Workers.MountWorker.ping()

# 2. Инициализация
SolarObservations.Workers.MountWorker.initialize("3")

# 3. Проверка статуса
{:ok, s1} = SolarObservations.Workers.MountWorker.get_status("1")
{:ok, s2} = SolarObservations.Workers.MountWorker.get_status("2")

# 4. Параметры монтировки
{:ok, cpr} = SolarObservations.Workers.MountWorker.get_cpr("1")
{:ok, tmr_freq} = SolarObservations.Workers.MountWorker.get_timer_freq()

# 5. Расчёт T1_Preset
t1_preset = round(tmr_freq * 360.0 / (360.0 / 86164.1 * (365.25 / 366.25)) / cpr)

# 6. Режим слежения
SolarObservations.Workers.MountWorker.set_motion_mode("1", 0x01, 0x00)

# 7. Установка периода
SolarObservations.Workers.MountWorker.set_step_period("1", t1_preset)

# 8. Старт
SolarObservations.Workers.MountWorker.start_motion("1")

# 9. Проверка
SolarObservations.Workers.MountWorker.get_status("1")
SolarObservations.Workers.MountWorker.is_motor_moving?("1", 1000)

# Стоп
SolarObservations.Workers.MountWorker.stop_motion("1")






SolarObservations.Workers.MountWorker.sync_to_sun()

# Навестись на Солнце и сразу начать слежение
SolarObservations.Workers.MountWorker.goto_sun()

# Или раздельно — сначала посмотреть куда будет наводка
{:ok, sun} = SolarObservations.Workers.MountWorker.get_sun_position()
IO.inspect(sun)

# Затем навестись
SolarObservations.Workers.MountWorker.goto_sun()

# Если уже наведены вручную — просто запустить слежение
SolarObservations.Workers.MountWorker.start_solar_tracking()

# Стоп
SolarObservations.Workers.MountWorker.stop_motion("1")


SolarObservations.Workers.MountWorker.stop_and_return_home()