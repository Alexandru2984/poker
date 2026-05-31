defmodule MicuPoker.Poker.Actions do
  @moduledoc false

  @actions [:fold, :check, :call, :bet, :raise, :all_in]
  def all, do: @actions
end
