defmodule MicuPokerWeb.TableLayoutTest do
  use ExUnit.Case, async: true

  alias MicuPokerWeb.TableLayout

  defp player(seat, attrs \\ %{}) do
    Map.merge(%{seat_number: seat, username: "P#{seat}", bet: 0}, attrs)
  end

  defp table(seats, players, attrs \\ %{}) do
    Map.merge(
      %{
        players: players,
        pot: 0,
        room: %{max_players: seats},
        valid_actions: %{}
      },
      attrs
    )
  end

  describe "seats/2" do
    test "returns one entry per seat, including empty ones" do
      seats = TableLayout.seats(table(6, [player(2)]), 2)

      assert length(seats) == 6
      assert Enum.count(seats, &is_nil(&1.player)) == 5
    end

    test "the viewer is always first and always at the bottom" do
      for viewer_seat <- 1..6 do
        [first | _rest] = TableLayout.seats(table(6, [player(viewer_seat)]), viewer_seat)

        assert first.seat_number == viewer_seat
        assert first.hero?
        assert first.position == 0
        assert first.x == 50.0
        assert first.y > 50
      end
    end

    test "the seat to the viewer's left is drawn on their left" do
      seats = TableLayout.seats(table(6, []), 1)
      left_neighbour = Enum.find(seats, &(&1.position == 1))

      assert left_neighbour.seat_number == 2
      assert left_neighbour.x < 50
    end

    test "positions wrap around the table" do
      seats = TableLayout.seats(table(6, []), 5)

      assert Enum.map(seats, & &1.seat_number) == [5, 6, 1, 2, 3, 4]
    end

    test "seats are spread evenly for any table size" do
      for total <- 2..9 do
        seats = TableLayout.seats(table(total, []), 1)

        assert length(seats) == total
        assert Enum.map(seats, & &1.position) == Enum.to_list(0..(total - 1))
      end
    end

    test "heads-up puts the opponent directly opposite" do
      [hero, villain] = TableLayout.seats(table(2, []), 1)

      assert hero.x == villain.x
      assert hero.y > 50
      assert villain.y < 50
    end

    test "every seat stays inside the felt" do
      for total <- 2..9, seat <- TableLayout.seats(table(total, []), 1) do
        assert seat.x >= 5 and seat.x <= 95
        assert seat.y >= 5 and seat.y <= 95
      end
    end

    test "a spectator with no seat still gets a stable layout" do
      seats = TableLayout.seats(table(6, [player(3)]), nil)

      assert length(seats) == 6
      assert hd(seats).seat_number == 3
    end

    test "a room that shrank still renders every seated player" do
      seats = TableLayout.seats(table(2, [player(1), player(5)]), 1)

      assert length(seats) == 5
      assert Enum.find(seats, &(&1.seat_number == 5)).player
    end

    test "seat_style/1 emits placement custom properties" do
      style = TableLayout.seat_style(%{x: 12.5, y: 80.0})

      assert style == "--seat-x:12.5%;--seat-y:80.0%"
    end
  end

  describe "bet_presets/1" do
    defp betting_table(pot, actions, players \\ []) do
      table(6, players, %{pot: pot, valid_actions: actions})
    end

    test "returns nothing when no bet is legal" do
      assert TableLayout.bet_presets(betting_table(100, %{actions: []})) == []
    end

    test "sizes are taken from the pot including bets on the table" do
      presets =
        betting_table(
          100,
          %{min_bet: 10, max_total_bet: 1000},
          [player(1, %{bet: 50}), player(2, %{bet: 50})]
        )
        |> TableLayout.bet_presets()

      # Pot of 100 plus 100 already wagered this street.
      assert {"Pot", 200} in presets
      assert {"½ pot", 100} in presets
    end

    test "presets never fall below the legal minimum" do
      presets =
        betting_table(10, %{min_raise_to: 400, max_total_bet: 1000})
        |> TableLayout.bet_presets()

      assert Enum.all?(presets, fn {_label, amount} -> amount >= 400 end)
    end

    test "presets never exceed the player's stack" do
      presets =
        betting_table(10_000, %{min_bet: 10, max_total_bet: 250})
        |> TableLayout.bet_presets()

      assert Enum.all?(presets, fn {_label, amount} -> amount <= 250 end)
    end

    test "duplicate sizes collapse to one button" do
      presets =
        betting_table(10_000, %{min_bet: 10, max_total_bet: 250})
        |> TableLayout.bet_presets()

      amounts = Enum.map(presets, fn {_label, amount} -> amount end)

      assert amounts == Enum.uniq(amounts)
    end

    test "an impossible range yields no presets" do
      assert TableLayout.bet_presets(betting_table(100, %{min_raise_to: 900, max_total_bet: 200})) ==
               []
    end
  end
end
