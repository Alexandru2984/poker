defmodule MicuPoker.Rooms.RoomJanitor do
  @moduledoc """
  Periodically completes stale rooms and releases stale seats.
  """

  use GenServer

  alias MicuPoker.{Accounts, Rooms}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      Process.send_after(self(), :run, initial_delay_ms())
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:run, state) do
    Rooms.expire_stale_rooms()
    Accounts.delete_unused_guest_users()
    Process.send_after(self(), :run, interval_ms())
    {:noreply, state}
  end

  defp enabled? do
    Application.get_env(:micu_poker, :room_janitor_enabled, true) &&
      System.get_env("ROOM_JANITOR_ENABLED", "true") == "true"
  end

  defp initial_delay_ms,
    do: System.get_env("ROOM_JANITOR_INITIAL_DELAY_MS", "30000") |> String.to_integer()

  defp interval_ms do
    minutes = System.get_env("ROOM_JANITOR_INTERVAL_MINUTES", "15") |> String.to_integer()
    minutes * 60_000
  end
end
