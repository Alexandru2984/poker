defmodule MicuPoker.ConfigTest do
  # Not async: these tests mutate the OS environment, which is global.
  use ExUnit.Case, async: false

  alias MicuPoker.Config

  @var "MICUPOKER_CONFIG_TEST_VAR"

  setup do
    on_exit(fn -> System.delete_env(@var) end)
    System.delete_env(@var)
    :ok
  end

  describe "integer/3" do
    test "reads a valid value" do
      System.put_env(@var, "42")
      assert Config.integer(@var, 7) == 42
    end

    test "tolerates surrounding whitespace" do
      System.put_env(@var, "  42\n")
      assert Config.integer(@var, 7) == 42
    end

    test "falls back when unset" do
      assert Config.integer(@var, 7) == 7
    end

    test "falls back on a non-numeric value instead of raising" do
      System.put_env(@var, "six")
      assert Config.integer(@var, 7) == 7
    end

    test "falls back on trailing garbage rather than silently truncating" do
      System.put_env(@var, "42players")
      assert Config.integer(@var, 7) == 7
    end

    test "falls back on an empty value" do
      System.put_env(@var, "")
      assert Config.integer(@var, 7) == 7
    end

    test "rejects a value below the minimum" do
      System.put_env(@var, "-1")
      assert Config.integer(@var, 7) == 7
    end

    test "allows zero by default" do
      System.put_env(@var, "0")
      assert Config.integer(@var, 7) == 0
    end

    test "honours an explicit minimum" do
      System.put_env(@var, "0")
      assert Config.integer(@var, 30, min: 1) == 30
    end

    test "honours an explicit maximum" do
      System.put_env(@var, "500")
      assert Config.integer(@var, 9, min: 2, max: 10) == 9
    end

    test "accepts a value at both bounds" do
      System.put_env(@var, "10")
      assert Config.integer(@var, 9, min: 2, max: 10) == 10

      System.put_env(@var, "2")
      assert Config.integer(@var, 9, min: 2, max: 10) == 2
    end
  end

  describe "boolean/2" do
    test "reads the spellings operators actually type" do
      for value <- ~w(true TRUE 1 yes on  True ) do
        System.put_env(@var, value)
        assert Config.boolean(@var, false), "expected #{inspect(value)} to be true"
      end

      for value <- ~w(false FALSE 0 no off) do
        System.put_env(@var, value)
        refute Config.boolean(@var, true), "expected #{inspect(value)} to be false"
      end
    end

    test "falls back when unset" do
      assert Config.boolean(@var, true)
      refute Config.boolean(@var, false)
    end

    # A typo must not disable a feature that defaults to on.
    test "falls back on an unrecognised value" do
      System.put_env(@var, "maybe")
      assert Config.boolean(@var, true)
    end
  end

  describe "list/1" do
    test "splits and trims" do
      System.put_env(@var, "127.0.0.1/32, ::1/128 ,")
      assert Config.list(@var) == ["127.0.0.1/32", "::1/128"]
    end

    test "returns nil when unset so callers can tell it apart from empty" do
      assert Config.list(@var) == nil
    end

    test "returns an empty list when configured blank" do
      System.put_env(@var, " , ")
      assert Config.list(@var) == []
    end
  end

  describe "callers" do
    test "a malformed MAX_PLAYERS_PER_ROOM no longer crashes the lobby" do
      System.put_env("MAX_PLAYERS_PER_ROOM", "nine")
      on_exit(fn -> System.delete_env("MAX_PLAYERS_PER_ROOM") end)

      assert MicuPoker.Rooms.Room.max_players() == 9
    end

    test "MAX_PLAYERS_PER_ROOM is capped at the ten-seat table limit" do
      System.put_env("MAX_PLAYERS_PER_ROOM", "50")
      on_exit(fn -> System.delete_env("MAX_PLAYERS_PER_ROOM") end)

      assert MicuPoker.Rooms.Room.max_players() == 9
    end

    test "a malformed MAX_ROOMS falls back instead of raising" do
      System.put_env("MAX_ROOMS", "lots")
      on_exit(fn -> System.delete_env("MAX_ROOMS") end)

      assert MicuPoker.Rooms.max_rooms() == 100
    end
  end
end
