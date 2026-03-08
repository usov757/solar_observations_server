defmodule SolarObservations.Repo do
  use Ecto.Repo,
    otp_app: :solar_observations,
    adapter: Ecto.Adapters.Postgres
end
