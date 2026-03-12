# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     SolarObservations.Repo.insert!(%SolarObservations.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias SolarObservations.Repo
alias SolarObservations.Mount
alias SolarObservations.Camera
alias SolarObservations.ObservingSession
alias SolarObservations.SessionEvent

# Удаляем старые данные (при необходимости)
Repo.delete_all(SessionEvent)
Repo.delete_all(ObservingSession)
Repo.delete_all(Camera)
Repo.delete_all(Mount)

# Создаем основную монтировку с конфигурацией из config/dev.exs
default_mount = %Mount{
  name: "SkyWatcher EQ6-R Pro",
  port: "/dev/ttyUSB0",
  connection_type: "serial",
  baud_rate: 9600,
  reconnect_interval: 5000,
  latitude: Decimal.new("50.2828"),
  longitude: Decimal.new("127.5299"),
  initialized: false
}

mount = Repo.insert!(default_mount)
IO.puts("✓ Created mount: #{mount.name}")

# Создаем тестовую камеру
camera = %Camera{
  name: "ASI174MM",
  device_id: "USB3.0-1.1",
  focal_length_mm: Decimal.new("1000.00"),
  default_exposure: Decimal.new("0.001"),
  default_gain: 100,
  mount_id: mount.id
}

Repo.insert!(camera)
IO.puts("✓ Created camera: #{camera.name}")

# Создаем тестовую сессию наблюдений
observing_session = %ObservingSession{
  mount_id: mount.id,
  started_at: DateTime.utc_now() |> DateTime.truncate(:second),
  status: "active",
  target_name: "Sun",
  notes: "Initial test session"
}

session = Repo.insert!(observing_session)
IO.puts("✓ Created observing session: #{session.target_name}")

# Создаем несколько тестовых событий
events = [
  %SessionEvent{
    observing_session_id: session.id,
    occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
    event_type: "system",
    message: "Mount system initialized",
    success: true
  },
  %SessionEvent{
    observing_session_id: session.id,
    occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
    event_type: "mount_command",
    raw_command: ":F3\\r",
    raw_response: "=\\r",
    message: "Mount initialized successfully",
    success: true
  }
]

Enum.each(events, fn event -> Repo.insert!(event) end)
IO.puts("✓ Created #{length(events)} session events")

IO.puts("\nDatabase seeded successfully!")
IO.puts("Mount ID: #{mount.id}")
IO.puts("Camera ID: #{camera.id}")
IO.puts("Session ID: #{session.id}")
