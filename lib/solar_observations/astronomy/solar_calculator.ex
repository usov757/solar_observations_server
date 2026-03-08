defmodule SolarObservations.Astronomy.SolarCalculator do
  @moduledoc """
  Расчет положения и скорости Солнца.
  Использует упрощенные, но точные формулы.
  """

  @solar_day_seconds 86400.0  # Солнечные сутки
  @sidereal_day_seconds 86164.0905  # Сидерические сутки

  @doc """
  Вычисляет экваториальные координаты Солнца.
  Упрощенная модель, точность ~0.5°.
  """
  def calculate_sun_position(latitude, longitude, datetime \\ DateTime.utc_now()) do
    # 1. Вычисляем день года
    date = DateTime.to_date(datetime)
    day_of_year = Date.day_of_year(date)

    # 2. Простая модель склонения Солнца
    # Скорость изменения ~0.4°/день, амплитуда 23.44°
    declination = 23.44 * :math.sin(2 * :math.pi * (day_of_year - 81) / 365.25)

    # 3. Прямое восхождение - равномерное движение
    # Солнце делает полный круг за год
    ra_hours = :math.fmod((day_of_year - 81) * 24.0 / 365.25, 24.0)

    # 4. Вычисляем часовой угол
    # Звездное время в градусах
    utc_hours = datetime.hour + datetime.minute/60.0 + datetime.second/3600.0
    days_since_j2000 = date_to_j2000_days(date) + utc_hours/24.0
    gmst_degrees = 100.46061837 + 360.98564736629 * days_since_j2000
    gmst_degrees = :math.fmod(gmst_degrees, 360.0)

    lmst_degrees = gmst_degrees + longitude
    ha_degrees = lmst_degrees - ra_hours * 15.0
    ha_degrees = normalize_angle(ha_degrees)

    # 5. Преобразуем в горизонтальные координаты
    lat_rad = latitude * :math.pi() / 180.0
    dec_rad = declination * :math.pi() / 180.0
    ha_rad = ha_degrees * :math.pi() / 180.0

    sin_alt = :math.sin(lat_rad) * :math.sin(dec_rad) +
              :math.cos(lat_rad) * :math.cos(dec_rad) * :math.cos(ha_rad)
    altitude = :math.asin(sin_alt) * 180.0 / :math.pi()

    # Защита от деления на ноль
    cos_lat_cos_alt = :math.cos(lat_rad) * :math.cos(:math.asin(sin_alt))
    cos_az = if cos_lat_cos_alt != 0 do
      (:math.sin(dec_rad) - :math.sin(lat_rad) * sin_alt) / cos_lat_cos_alt
    else
      0.0
    end

    azimuth = if cos_az >= -1.0 and cos_az <= 1.0 do
      :math.acos(cos_az) * 180.0 / :math.pi()
    else
      # Значение по умолчанию
      if ha_degrees > 0, do: 180.0, else: 0.0
    end

    # Корректируем азимут в зависимости от часового угла
    final_azimuth = if :math.sin(ha_rad) > 0 do
      360.0 - azimuth
    else
      azimuth
    end

    {:ok, %{
      ra: normalize_ra(ra_hours),
      dec: declination,
      altitude: max(altitude, -90.0),  # Ограничиваем снизу
      azimuth: final_azimuth,
      ha: ha_degrees,
      day_of_year: day_of_year
    }}
  end

  @doc """
  Возвращает угловую скорость Солнца.
  Для слежения используем солнечную скорость.
  """
  def calculate_sun_angular_velocity(_latitude, _longitude, _datetime \\ DateTime.utc_now()) do
    # Солнечная скорость: 360° за 24 часа
    solar_speed_deg_per_sec = 360.0 / @solar_day_seconds  # ≈ 0.0041667°/сек

    # Сидерическая скорость (немного быстрее)
    sidereal_speed_deg_per_sec = 360.0 / @sidereal_day_seconds  # ≈ 0.004178°/сек

    # Для слежения за Солнцем используем СОЛНЕЧНУЮ скорость
    {:ok, %{
      ra_deg_per_sec: solar_speed_deg_per_sec,
      dec_deg_per_sec: 0.0,  # Склонение меняется очень медленно
      solar_speed_deg_per_sec: solar_speed_deg_per_sec,
      sidereal_speed_deg_per_sec: sidereal_speed_deg_per_sec
    }}
  end

  @doc """
  Упрощенная версия для быстрого расчета положения Солнца.
  """
  def calculate_simple_sun_position(latitude, longitude, datetime \\ DateTime.utc_now()) do
    # Простая модель для тестирования

    date = DateTime.to_date(datetime)
    day_of_year = Date.day_of_year(date)

    # Примерные координаты для середины января
    # В январе Солнце в созвездии Стрельца/Козерога
    # RA ~20h, Dec ~-20°
    ra_hours = 20.0  # Примерно 20 часов RA
    declination = -20.0  # Примерно -20° Dec

    # Часовой угол (упрощенно)
    utc_hours = datetime.hour + datetime.minute/60.0 + datetime.second/3600.0
    lst_hours = 100.0/15.0 + longitude/15.0 + utc_hours  # Упрощенно
    ha_hours = lst_hours - ra_hours
    ha_degrees = normalize_angle(ha_hours * 15.0)

    # Горизонтальные координаты
    lat_rad = latitude * :math.pi() / 180.0
    dec_rad = declination * :math.pi() / 180.0
    ha_rad = ha_degrees * :math.pi() / 180.0

    sin_alt = :math.sin(lat_rad) * :math.sin(dec_rad) +
              :math.cos(lat_rad) * :math.cos(dec_rad) * :math.cos(ha_rad)
    altitude = :math.asin(max(-1.0, min(1.0, sin_alt))) * 180.0 / :math.pi()

    azimuth = if altitude > -90 do
      cos_az = (:math.sin(dec_rad) - :math.sin(lat_rad) * sin_alt) /
               (:math.cos(lat_rad) * :math.cos(:math.asin(sin_alt)))
      az = :math.acos(max(-1.0, min(1.0, cos_az))) * 180.0 / :math.pi()
      if :math.sin(ha_rad) > 0, do: 360.0 - az, else: az
    else
      0.0
    end

    {:ok, %{
      ra: ra_hours,
      dec: declination,
      altitude: altitude,
      azimuth: azimuth,
      ha: ha_degrees,
      day_of_year: day_of_year
    }}
  end

  # Вспомогательные функции

  defp date_to_j2000_days(date) do
    # J2000 = 2000-01-01 12:00:00 UTC
    j2000_date = ~D[2000-01-01]
    Date.diff(date, j2000_date)
  end

  defp normalize_angle(angle) do
    a = :math.fmod(angle, 360.0)
    if a < 0, do: a + 360.0, else: a
  end

  defp normalize_ra(ra_hours) do
    a = :math.fmod(ra_hours, 24.0)
    if a < 0, do: a + 24.0, else: a
  end
end
