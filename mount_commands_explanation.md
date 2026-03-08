# Команды для монтировки и интерпретация скорости наблюдения

## Файлы с командами для монтировки

### 1. Основной файл с командами: `lib/solar_observations/workers/mount_worker.ex`

Этот файл содержит GenServer для управления монтировкой SkyWatcher через последовательный порт. Основные команды:

**Базовые команды:**

- `initialize/2` - инициализация монтировки (`:F3\r`)
- `get_position/2` - получение текущей позиции (`:j1\r`, `:j2\r`)
- `get_status/2` - получение статуса (`:f1\r`, `:f2\r`)
- `start_motion/2` - запуск движения (`:J3\r`)
- `stop_motion/2` - остановка движения (`:K3\r`)
- `instant_stop/2` - мгновенная остановка (`:L3\r`)

**Команды для слежения:**

- `set_motion_mode/3` - установка режима движения (`:G1<hex>\r`, `:G2<hex>\r`)
  - `0x00` - GOTO режим
  - `0x03` - Tracking режим (слежение CCW)
- `set_step_period/3` - установка периода шагов (`:I1<hex24>\r`, `:I2<hex24>\r`)
  - Определяет скорость движения через T1_Preset
- `set_goto_target/3` - установка цели для GOTO (`:S1<hex24>\r`, `:S2<hex24>\r`)

**Команды для получения параметров:**

- `get_cpr/2` - получение Counts Per Revolution (`:a1\r`, `:a2\r`)
- `get_timer_freq/2` - получение частоты таймера (`:b1\r`, `:b2\r`)
- `get_high_speed_ratio/2` - получение коэффициента high-speed режима (`:g1\r`, `:g2\r`)

### 2. Файл управления слежением: `lib/solar_observations/astronomy/solar_tracker.ex`

Этот файл содержит логику для автоматического слежения за Солнцем. Ключевые функции:

**Основные функции:**

- `start_tracking/1` - запуск слежения за Солнцем
- `start_solar_tracking/1` - настройка и запуск слежения
- `calculate_t1_preset/4` - расчет T1_Preset для заданной скорости

**Вспомогательные функции:**

- `check_connection/0` - проверка соединения с монтировкой
- `stop_and_reset_motors/0` - остановка и сброс моторов
- `goto_to_sun/2` - наведение на Солнце (GOTO)
- `verify_tracking_mode/0` - проверка режима слежения
- `verify_movement/0` - проверка движения моторов

## Правильная интерпретация скорости наблюдения

### Формула расчета T1_Preset

**Исправленная формула (из документации SkyWatcher):**

```
T1_Preset = N * TMR_Freq * 360 / (Speed_DegPerSec * CPR)
```

Где:

- `N` = high_speed_ratio (обычно 16, 32 или 64)
- `TMR_Freq` = частота таймера (обычно ~9.83 MHz)
- `Speed_DegPerSec` = скорость в градусах/секунду
- `CPR` = Counts Per Revolution (шагов на полный оборот)

### Пример для солнечного слежения

1. **Солнечная скорость:** 15.041°/час = 0.0041780556°/сек
2. **Типичные параметры SkyWatcher EQ6:**
   - CPR = 134,217,728 (2^27 шагов)
   - TMR_Freq = 9,830,400 Гц
   - High_speed_ratio = 64
3. **Расчет T1_Preset:**
   ```
   T1_Preset = 64 * 9,830,400 * 360 / (0.0041780556 * 134,217,728)
   T1_Preset = 403,896
   ```

### Как это работает в коде

1. **В `solar_tracker.ex` функция `calculate_t1_preset/4`:**

```elixir
def calculate_t1_preset(speed_deg_per_sec, cpr, timer_freq, high_speed_ratio \\ 1) do
  # Прямая формула из документации SkyWatcher
  t1_preset = trunc(high_speed_ratio * timer_freq * 360 / (speed_deg_per_sec * cpr))
  # Ограничения: 6 ≤ T1_Preset ≤ 16777215
  max(6, min(t1_preset, 16777215))
end
```

2. **Использование в `start_solar_tracking/1`:**

```elixir
# Рассчитываем солнечную скорость
solar_speed_deg_per_sec = @solar_speed_deg_per_hour / 3600.0

# Рассчитываем T1_Preset для оси RA
case calculate_t1_preset(
  solar_speed_deg_per_sec,
  mount_params.axis1_cpr,
  mount_params.timer_freq,
  mount_params.high_speed_ratio
) do
  {:ok, t1_preset} ->
    # Устанавливаем период шагов
    MountWorker.set_step_period("1", t1_preset, timeout)
```

### Практическое применение

1. **Для солнечного слежения:**
   - Скорость: 15.041°/час
   - T1_Preset: ~403,896
   - Режим: 0x03 (Tracking CCW)

2. **Для сидерического слежения:**
   - Скорость: 15.0410678°/час
   - T1_Preset: ~403,894
   - Режим: 0x03 (Tracking CCW)

3. **Для GOTO (быстрое движение):**
   - Скорость: 500-1000°/час
   - T1_Preset: 6,075-12,150
   - Режим: 0x00 (GOTO)

### Проверка правильности скорости

Для проверки можно использовать обратную формулу:

```
Speed_DegPerSec = N * TMR_Freq * 360 / (T1_Preset * CPR)
```

Пример проверки:

```elixir
# Для T1_Preset = 403,896
speed = 64 * 9_830_400 * 360 / (403_896 * 134_217_728)
speed = 0.0041780557°/сек = 15.041°/час
```

## Рекомендации

1. **Всегда получать реальные параметры** с монтировки через:
   - `MountWorker.get_cpr/2`
   - `MountWorker.get_timer_freq/2`
   - `MountWorker.get_high_speed_ratio/2`

2. **Использовать high-speed режим** для скоростей ниже ~100°/час

3. **Проверять граничные значения:**
   - Минимальный T1_Preset = 6 (максимальная скорость)
   - Максимальный T1_Preset = 16,777,215 (минимальная скорость)

4. **Для точного слежения** учитывать:
   - Уравнение времени (разница между солнечным и средним временем)
   - Атмосферную рефракцию
   - Прецессию и нутацию
