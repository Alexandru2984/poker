defmodule MicuPoker.Release do
  @moduledoc false

  @app :micu_poker

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, fn repo -> Ecto.Migrator.run(repo, :up, all: true) end)
    end
  end

  defp load_app do
    Application.load(@app)
  end
end
