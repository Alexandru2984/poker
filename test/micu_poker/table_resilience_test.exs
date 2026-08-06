defmodule MicuPoker.Poker.TableResilienceTest do
  @moduledoc """
  How the table behaves when it is missing, restarting, or fed bad input.
  """

  use MicuPoker.DataCase

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPoker.Rooms

  setup do
    {:ok, user} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(%{"name" => "Resilience Table", "max_players" => "3"}, user.id)

    %{room: room, user: user}
  end

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  describe "calls against a table that is not running" do
    test "state/2 returns nil instead of exiting the caller", %{room: room, user: user} do
      assert TableServer.state(room.id, user.id) == nil
    end

    test "act/4 reports the table as unavailable", %{room: room, user: user} do
      assert {:error, :table_unavailable} = TableServer.act(room.id, user.id, "fold", 0)
    end

    test "chat/3 reports the table as unavailable", %{room: room, user: user} do
      assert {:error, :table_unavailable} = TableServer.chat(room.id, user.id, "hello")
    end

    test "join/2 reports the table as unavailable", %{room: room, user: user} do
      assert {:error, :table_unavailable} = TableServer.join(room.id, user.id)
    end

    test "leave/2 does not raise when the table already stopped", %{room: room, user: user} do
      assert {:error, :table_unavailable} = TableServer.leave(room.id, user.id)
    end

    test "the caller process stays alive throughout", %{room: room, user: user} do
      TableServer.state(room.id, user.id)
      TableServer.act(room.id, user.id, "fold", 0)

      assert Process.alive?(self())
    end
  end

  describe "malformed input" do
    setup %{room: room} do
      start_supervised!({TableServer, room.id})
      :ok
    end

    test "an unknown action name is rejected, not crashed on", %{room: room, user: user} do
      assert {:ok, _state} = TableServer.join(room.id, user.id)

      assert {:error, _reason} = TableServer.act(room.id, user.id, "not_a_real_action", 0)
      assert {:error, _reason} = TableServer.act(room.id, user.id, "Elixir.System", 0)
    end

    test "a non-integer amount does not crash the table", %{room: room, user: user} do
      assert {:ok, _state} = TableServer.join(room.id, user.id)

      assert {:error, _reason} = TableServer.act(room.id, user.id, "bet", "not-a-number")
      assert {:error, _reason} = TableServer.act(room.id, user.id, "bet", %{"nested" => true})
      assert {:error, _reason} = TableServer.act(room.id, user.id, "bet", nil)

      assert TableServer.state(room.id, user.id)
    end

    test "a malformed environment variable falls back to the default", %{
      room: room,
      user: user
    } do
      previous = System.get_env("TURN_TIMEOUT_SECONDS")
      System.put_env("TURN_TIMEOUT_SECONDS", "not-a-number")

      on_exit(fn ->
        if previous,
          do: System.put_env("TURN_TIMEOUT_SECONDS", previous),
          else: System.delete_env("TURN_TIMEOUT_SECONDS")
      end)

      {:ok, other} = Accounts.create_guest_user()

      assert {:ok, _} = TableServer.join(room.id, user.id)
      assert {:ok, _} = TableServer.connect(room.id, user.id, make_ref())
      assert {:ok, _} = TableServer.join(room.id, other.id)
      assert {:ok, state} = TableServer.connect(room.id, other.id, make_ref())

      # The hand still started, with the default 30 second clock.
      assert state.stage == :preflop
      assert state.action_deadline
    end
  end

  describe "table lifecycle" do
    setup do
      previous = System.get_env("TABLE_IDLE_SHUTDOWN_MINUTES")
      System.put_env("TABLE_IDLE_SHUTDOWN_MINUTES", "0")

      on_exit(fn ->
        if previous,
          do: System.put_env("TABLE_IDLE_SHUTDOWN_MINUTES", previous),
          else: System.delete_env("TABLE_IDLE_SHUTDOWN_MINUTES")
      end)

      :ok
    end

    test "an idle table with no connections shuts itself down", %{room: room, user: user} do
      pid = start_supervised!({TableServer, room.id}, restart: :temporary)
      ref = Process.monitor(pid)

      assert {:ok, _state} = TableServer.join(room.id, user.id)
      send(pid, :check_idle)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      # The registry drops the entry asynchronously once the process is gone.
      assert eventually(fn -> TableSupervisor.lookup_table(room.id) == :not_found end)
    end

    test "a table with a connected player is never shut down as idle", %{
      room: room,
      user: user
    } do
      pid = start_supervised!({TableServer, room.id}, restart: :temporary)

      assert {:ok, _} = TableServer.join(room.id, user.id)
      assert {:ok, _} = TableServer.connect(room.id, user.id, make_ref())

      send(pid, :check_idle)

      # A synchronous call after the message proves it was processed.
      assert TableServer.state(room.id, user.id)
      assert Process.alive?(pid)
    end

    test "rate limit stamps for players no longer seated are dropped", %{
      room: room,
      user: user
    } do
      pid = start_supervised!({TableServer, room.id}, restart: :temporary)

      assert {:ok, _} = TableServer.join(room.id, user.id)
      assert {:ok, _} = TableServer.connect(room.id, user.id, make_ref())
      assert :ok = TableServer.chat(room.id, user.id, "hi")

      # Stand in for a player who sat, chatted and has since been removed. The
      # stamp map used to keep an entry for every player the table ever saw.
      departed_id = -1
      :sys.replace_state(pid, &put_in(&1, [:rate_limits, :chat, departed_id], 0))

      send(pid, :check_idle)
      assert TableServer.state(room.id, user.id)

      stamps = :sys.get_state(pid).rate_limits.chat

      assert Map.has_key?(stamps, user.id)
      refute Map.has_key?(stamps, departed_id)
    end
  end
end
