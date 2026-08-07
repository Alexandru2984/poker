defmodule MicuPokerWeb.LeaderboardHTML do
  use MicuPokerWeb, :html

  embed_templates "leaderboard_html/*"

  @doc """
  Formats a signed chip total, so a loss reads as a loss at a glance.
  """
  def signed(amount) when is_integer(amount) and amount > 0, do: "+#{amount}"
  def signed(amount) when is_integer(amount), do: Integer.to_string(amount)
  def signed(_amount), do: "0"

  def sign_class(amount) when is_integer(amount) and amount > 0, do: "up"
  def sign_class(amount) when is_integer(amount) and amount < 0, do: "down"
  def sign_class(_amount), do: nil
end
