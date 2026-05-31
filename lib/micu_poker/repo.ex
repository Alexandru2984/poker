defmodule MicuPoker.Repo do
  use Ecto.Repo,
    otp_app: :micu_poker,
    adapter: Ecto.Adapters.Postgres
end
