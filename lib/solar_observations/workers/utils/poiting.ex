defmodule SolarObservations.Workers.Utils.Pointing do
  @moduledoc """
  Математика наводки монтировки на Солнце.

  Чистые функции — не зависят от GenServer, Repo или UART.
  Используются только внутри Workers.MountWorker.

  ## Система координат

    HOME = RA ось на меридиане, Dec ось смотрит на полюс (+90°)

    axis1 (RA):  target_steps = HA × CPR/360
      HA = LST - RA_sun; HA > 0 → CW, HA < 0 → CCW

    axis2 (Dec): target_steps = (Dec_sun - 90°) × CPR/360
      Для Солнца Dec < 90° → target всегда < 0 → CCW

  ## Астрономия

    Формулы: Jean Meeus "Astronomical Algorithms", точность ~0.01° (~36″).
    Эпоха: J2000.0 (JD 2_451_545.0 = 2000-01-01 12:00 UTC).
  """

  # ===========================================================================
  # Позиция Солнца и время
  # ===========================================================================

  @doc """
  Вычисляет положение Солнца и высоту над горизонтом для наблюдателя.

  Возвращает:
    %{ra: float, dec: float, altitude: float, azimuth: float, lst: float}
  где все углы в градусах, RA ∈ [0,360), Dec ∈ [-90,+90], altitude < 0 → за горизонтом.

  ## Параметры
    - datetime — UTC момент наблюдения (%DateTime{})
    - lat_deg  — широта наблюдателя (север > 0)
    - lon_deg  — долгота наблюдателя (восток > 0)
  """
  def calculate_sun_position(%DateTime{} = datetime, lat_deg, lon_deg) do
    jd  = julian_day(datetime)
    lst = local_sidereal_time(jd, lon_deg)

    {ra, dec}  = sun_ra_dec(jd)
    {alt, az}  = horizontal_coords(ra, dec, lst, lat_deg)

    %{ra: ra, dec: dec, altitude: alt, azimuth: az, lst: lst}
  end

  @doc """
  Вычисляет местное звёздное время (LST) в градусах [0, 360).

  ## Параметры
    - datetime — UTC момент
    - lon_deg  — долгота наблюдателя (восток > 0)
  """
  def calculate_lst(%DateTime{} = datetime, lon_deg) do
    jd = julian_day(datetime)
    local_sidereal_time(jd, lon_deg)
  end

  # ===========================================================================
  # Наводка и слежение
  # ===========================================================================

  @doc """
  Вычисляет целевые шаги для обеих осей.

  Возвращает `{:ok, {axis1_steps, axis2_steps}}`.
  Знак шагов определяет направление (do_goto в воркере читает знак).
  """
   def calculate_goto_steps(sun, lst, cpr) do
    ha            = normalize_ha(lst - sun.ra)
    # axis1 располагается ПЕРПЕНДИКУЛЯРНО направлению на Солнце:
    # труба (axis2) из этого положения довернёт на Dec и попадёт точно в цель
    axis1_perpendicular = normalize_ha(ha - 90.0)
    steps_per_deg       = cpr / 360.0
    axis1_steps         = round(axis1_perpendicular * steps_per_deg)
    axis2_steps         = round((sun.dec - 90.0)    * steps_per_deg)
    {:ok, {axis1_steps, axis2_steps}}
  end

  @doc """
  Вычисляет целевые шаги для коррекции Dec.
  """
  def calculate_dec_steps(sun, cpr),
    do: round((sun.dec - 90.0) * cpr / 360.0)

  @doc """
  Вычисляет T1 preset для солнечного слежения по RA.

    T1 = TMR_Freq / solar_speed_counts_per_sec
    solar_speed = sidereal × 365.25/366.25  (поправка на собственное движение Солнца)
  """
  def calculate_t1_preset(cpr, tmr_freq) do
    solar_deg_per_sec = 360.0 / 86_164.1 * (365.25 / 366.25)
    round(tmr_freq * 360.0 / solar_deg_per_sec / cpr)
  end

  @doc """
  DB2 байт для команды :G по знаку шагов.

    steps >= 0 → CW  → 0x0
    steps <  0 → CCW → 0x1
  """
  def direction_db2(steps) when steps >= 0, do: 0x0
  def direction_db2(_steps),                do: 0x1

  @doc "Метка направления для логов."
  def direction_label(steps) when steps >= 0, do: "CW"
  def direction_label(_steps),                do: "CCW"

  @doc "Проверяет высоту Солнца (минимум 5°)."
  def check_sun_visible(%{altitude: alt}) when alt < 5.0, do: {:error, {:sun_too_low, alt}}
  def check_sun_visible(_sun), do: :ok

  # ===========================================================================
  # Юлианская дата
  # ===========================================================================

  # JD для UTC момента.
  # J2000.0 = 2000-01-01 12:00:00 UTC = Unix 946_728_000 = JD 2_451_545.0
  defp julian_day(%DateTime{} = dt) do
    unix_seconds = DateTime.to_unix(dt, :second)
    2_451_545.0 + (unix_seconds - 946_728_000) / 86_400.0
  end

  # ===========================================================================
  # Звёздное время
  # ===========================================================================

  # Greenwich Mean Sidereal Time в градусах [0, 360).
  # Формула IAU, точность ~0.1″.
  defp greenwich_sidereal_time(jd) do
    t = (jd - 2_451_545.0) / 36_525.0

    gmst_sec =
      67_310.54841 +
      (876_600.0 * 3_600.0 + 8_640_184.812866) * t +
      0.093104 * t * t -
      6.2e-6   * t * t * t

    normalize_360(gmst_sec * 360.0 / 86_400.0)
  end

  defp local_sidereal_time(jd, lon_deg),
    do: normalize_360(greenwich_sidereal_time(jd) + lon_deg)

  # ===========================================================================
  # Положение Солнца (RA, Dec)
  # ===========================================================================

  # Упрощённая модель Meeus, точность ~0.01° (~36″).
  defp sun_ra_dec(jd) do
    n = jd - 2_451_545.0

    # Средняя долгота и аномалия
    l     = normalize_360(280.46646 + 36_000.76983 * n / 36_525.0)
    g_deg = normalize_360(357.52911 + 35_999.05029 * n / 36_525.0)
    g     = deg2rad(g_deg)

    # Уравнение центра
    c = 1.914602 * :math.sin(g) +
        0.019993 * :math.sin(2 * g) +
        0.000289 * :math.sin(3 * g)

    # Истинная эклиптическая долгота и наклон эклиптики
    sun_lon = normalize_360(l + c)
    epsilon = 23.439291 - 0.013004 * n / 36_525.0
    eps_rad = deg2rad(epsilon)
    lon_rad = deg2rad(sun_lon)

    ra_rad  = :math.atan2(:math.cos(eps_rad) * :math.sin(lon_rad), :math.cos(lon_rad))
    dec_rad = :math.asin(:math.sin(eps_rad) * :math.sin(lon_rad))

    {normalize_360(rad2deg(ra_rad)), rad2deg(dec_rad)}
  end

  # ===========================================================================
  # Горизонтальные координаты
  # ===========================================================================

  defp horizontal_coords(ra_deg, dec_deg, lst_deg, lat_deg) do
    ha_rad  = deg2rad(normalize_ha(lst_deg - ra_deg))
    dec_rad = deg2rad(dec_deg)
    lat_rad = deg2rad(lat_deg)

    sin_alt = :math.sin(dec_rad) * :math.sin(lat_rad) +
              :math.cos(dec_rad) * :math.cos(lat_rad) * :math.cos(ha_rad)
    alt = rad2deg(:math.asin(sin_alt))

    cos_az = (:math.sin(dec_rad) - :math.sin(lat_rad) * sin_alt) /
             (:math.cos(lat_rad) * :math.cos(deg2rad(alt)))
    az_raw = rad2deg(:math.acos(clamp(cos_az, -1.0, 1.0)))
    az     = if :math.sin(ha_rad) > 0, do: 360.0 - az_raw, else: az_raw

    {alt, az}
  end

  # ===========================================================================
  # Вспомогательные
  # ===========================================================================

  defp deg2rad(deg), do: deg * :math.pi() / 180.0
  defp rad2deg(rad), do: rad * 180.0 / :math.pi()

  defp normalize_360(x) do
    r = :math.fmod(x, 360.0)
    if r < 0, do: r + 360.0, else: r
  end

  defp normalize_ha(ha) when ha >  180.0, do: ha - 360.0
  defp normalize_ha(ha) when ha < -180.0, do: ha + 360.0
  defp normalize_ha(ha), do: ha

  defp clamp(x, min, _), do: max(x, min)
  defp clamp(x, _, max), do: min(x, max)
end
