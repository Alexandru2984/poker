defmodule MicuPokerWeb.TableLayout do
  @moduledoc """
  Seat geometry for the poker table.

  Two things the old fixed `.seat-1` … `.seat-9` rules could not do:

    * **Rotate to the viewer.** Every player expects to sit at the bottom of
      their own screen, with the player to their left on their left. Seats are
      therefore placed by their offset from the viewer's seat, not by their
      absolute seat number.
    * **Fit the table.** A six-max table drew its players into nine fixed
      positions and left a lopsided gap. Positions are spread evenly around an
      ellipse sized to the actual seat count.

  Coordinates come out as percentages of the felt and are handed to CSS as
  custom properties, so the same markup drives every table size.
  """

  # Percentage offsets from the centre of the felt. Kept inside the edges so a
  # seat card never clips, and wider than it is tall to match the felt's shape.
  @radius_x 40
  @radius_y 36

  @doc """
  Returns one entry per seat, ordered so the viewer comes first.

  Each entry carries the player sitting there (or nil for an empty seat) and
  the `x`/`y` percentages to place it at.
  """
  def seats(table, viewer_seat) do
    total = seat_count(table)
    occupied = Map.new(table.players, &{&1.seat_number, &1})
    anchor = viewer_seat || lowest_seat(table) || 1

    1..total
    |> Enum.map(fn seat ->
      position = Integer.mod(seat - anchor, total)
      {x, y} = coordinates(position, total)

      %{
        seat_number: seat,
        player: Map.get(occupied, seat),
        position: position,
        hero?: position == 0,
        x: x,
        y: y
      }
    end)
    |> Enum.sort_by(& &1.position)
  end

  @doc """
  Where a seat sits on the felt, as `{x_percent, y_percent}`.

  Position 0 is bottom centre. Increasing positions walk clockwise around the
  table as seen from the dealer, which puts the player to the viewer's left on
  the viewer's left.
  """
  def coordinates(position, total) when total > 0 do
    angle = :math.pi() / 2 + 2 * :math.pi() * position / total

    {
      round_to(50 + @radius_x * :math.cos(angle)),
      round_to(50 + @radius_y * :math.sin(angle))
    }
  end

  @doc """
  The inline style that places a seat, as CSS custom properties.
  """
  def seat_style(%{x: x, y: y}), do: "--seat-x:#{x}%;--seat-y:#{y}%"

  @doc """
  Bet-sizing presets for the action bar, clamped to what the player can afford.

  Returns `{label, total_bet}` pairs and drops any preset that is not a legal
  amount, so the UI never offers a button the server would reject.
  """
  def bet_presets(table) do
    actions = table.valid_actions
    minimum = actions[:min_raise_to] || actions[:min_bet]
    maximum = actions[:max_total_bet]

    if is_integer(minimum) and is_integer(maximum) and maximum >= minimum do
      pot = table.pot + Enum.sum(Enum.map(table.players, & &1.bet))

      [
        {"½ pot", div(pot, 2)},
        {"¾ pot", div(pot * 3, 4)},
        {"Pot", pot},
        {"Max", maximum}
      ]
      |> Enum.map(fn {label, amount} -> {label, clamp(amount, minimum, maximum)} end)
      |> Enum.uniq_by(fn {_label, amount} -> amount end)
    else
      []
    end
  end

  defp clamp(amount, minimum, maximum), do: amount |> max(minimum) |> min(maximum)

  defp seat_count(table) do
    # Never fewer seats than there are players, even if the room shrank.
    table.players
    |> Enum.map(& &1.seat_number)
    |> Enum.max(fn -> 0 end)
    |> max(table.room.max_players)
    |> max(2)
  end

  defp lowest_seat(table) do
    table.players |> Enum.map(& &1.seat_number) |> Enum.min(fn -> nil end)
  end

  defp round_to(value), do: Float.round(value * 1.0, 2)
end
