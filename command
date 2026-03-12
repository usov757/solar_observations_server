# MountWorker — шпаргалка для тестирования в iex

alias SolarObservations.Workers.MountWorker, as: W


## Диагностика

# Пинг (быстрая проверка связи)
W.ping()

# Полная диагностика: версия, статусы осей, позиции
{:ok, info} = W.check_connection()
IO.inspect(info)

# Статус каждой оси отдельно
{:ok, s1} = W.get_status("1")
{:ok, s2} = W.get_status("2")
# => %{running: bool, tracking_mode: bool, direction_ccw: bool, initialized: bool, ...}

# Текущие позиции в шагах (от HOME = 0)
{:ok, pos1} = W.get_position("1")
{:ok, pos2} = W.get_position("2")

# Движется ли ось прямо сейчас (сравнивает позицию дважды через 1 сек)
{:ok, moving?} = W.is_motor_moving?("1", 1000)

# Поворот RA на 360° по часовой
W.goto_degrees("1", 360.0)

# Поворот Dec на 360° против часовой
W.goto_degrees("2", -360.0)
---

## Параметры контроллера

```elixir
# Counts Per Revolution — шагов на полный оборот
{:ok, cpr} = W.get_cpr("1")

# Таймерная частота (нужна для расчёта T1)
{:ok, tmr_freq} = W.get_timer_freq()

# Соотношение высокой/низкой скоростей
{:ok, ratio} = W.get_high_speed_ratio("1")

# Версия прошивки
{:ok, ver} = W.get_version("1")
```

---

## Инициализация

```elixir
# Инициализировать обе оси (команда :F3)
W.initialize()         # обе оси
W.initialize("1")      # только RA
W.initialize("2")      # только Dec
```

---

## Ручное управление осями

```elixir
# --- Режим слежения (Tracking) ---
W.set_motion_mode("1", 0x01, 0x00)   # RA: Tracking, CW
W.set_step_period("1", t1_preset)
W.start_motion("1")

# --- Режим наводки (GOTO) ---
W.set_motion_mode("1", 0x00, 0x00)   # RA: GOTO, CW (target >= 0)
W.set_motion_mode("1", 0x00, 0x01)   # RA: GOTO, CCW (target < 0)
W.set_goto_target("1", 125_000)       # целевая позиция в шагах
W.start_motion("1")

# --- Остановка ---
W.stop_motion("1")     # плавная (внимание: переводит в Tracking mode!)
W.instant_stop("1")    # мгновенная, без смены режима
W.instant_stop("3")    # обе оси сразу
W.get_all_statuses()   # проверить статус после остановки

# --- Режим сна ---
W.set_sleep("1", true)
W.set_sleep("1", false)
```

---

## Поворот на градусы (кастомный GOTO)

```elixir
# Повернуть ось на N градусов от текущей позиции
# + CW, - CCW; ждёт окончания и останавливает
W.goto_degrees("1", 5.0)     # RA: +5° CW
W.goto_degrees("1", -5.0)    # RA: -5° CCW
W.goto_degrees("2", -10.0)   # Dec: -10° CCW

# Проверить куда приехали
{:ok, pos} = W.get_position("1")

# Расчёт шагов вручную для справки
{:ok, cpr} = W.get_cpr("1")
delta_steps = round(5.0 * cpr / 360.0)
```

---

## Солнечное слежение

```elixir
# Посмотреть куда сейчас смотрит Солнце (RA, Dec, Alt, Az)
{:ok, sun} = W.get_sun_position()
IO.inspect(sun)

# Навести на Солнце и сразу запустить слежение (полный цикл)
W.goto_sun()

# Если труба уже направлена вручную — только запустить слежение
W.start_solar_tracking()

# Запустить слежение с известными параметрами (не читать с контроллера)
W.start_solar_tracking(9_024_000, 64_935_800)

# Синхронизация: запомнить текущее положение как позицию Солнца
W.sync_to_sun()

# Остановить слежение и вернуться в HOME (0, 0)
W.stop_and_return_home()
```

---

## Расчёт T1_Preset вручную

```elixir
{:ok, cpr}      = W.get_cpr("1")
{:ok, tmr_freq} = W.get_timer_freq()

solar_deg_per_sec = 360.0 / 86_164.1 * (365.25 / 366.25)
t1_preset = round(tmr_freq * 360.0 / solar_deg_per_sec / cpr)
# => ~592 для типичной SkyWatcher EQ5
```

---

## Типичные сценарии

```elixir
# 1. Быстрая проверка что всё работает
W.ping()
W.check_connection()

# 2. Проверка слежения вручную (шаг за шагом)
{:ok, cpr}      = W.get_cpr("1")
{:ok, tmr_freq} = W.get_timer_freq()
t1_preset = round(tmr_freq * 360.0 / (360.0 / 86_164.1 * (365.25 / 366.25)) / cpr)
W.initialize()
W.set_motion_mode("1", 0x01, 0x00)
W.set_step_period("1", t1_preset)
W.start_motion("1")
W.get_status("1")           # running: true ?
W.is_motor_moving?("1", 1000)
W.instant_stop("1")

# 3. Проверка GOTO на небольшой угол
W.initialize()
W.goto_degrees("1", 2.0)    # поехали на +2°
W.get_position("1")          # проверить позицию
W.goto_degrees("1", -2.0)   # вернуться
W.get_position("1")          # должно быть ~0

# 4. Полный рабочий цикл
W.goto_sun()                 # навестись и начать слежение
W.sync_to_sun()              # после ручной корректировки
W.stop_and_return_home()     # завершить сессию
```