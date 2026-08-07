defmodule MicuPoker.Config do
  @moduledoc """
  Reads operational settings from the environment.

  Every knob in `.env` is read at runtime rather than baked in at compile time,
  which means a typo in an operator's value must never take the node down. Each
  reader falls back to its documented default when the variable is missing,
  unparseable, or outside the range that makes sense for the setting, so a bad
  deploy degrades to shipped behaviour instead of crashing mid-hand.

  Before this module the same parse was written three different ways, including
  a bare `String.to_integer/1` inside `Room.max_players/0` — a value of `"six"`
  in `.env` raised `ArgumentError` on every page that rendered the lobby.
  """

  @doc """
  Reads an integer setting.

  Values below `:min` (0 by default) or above `:max` fall back to `default`,
  which keeps a plausible-looking but nonsensical value — a negative timeout, a
  20-seat table — from reaching the rest of the system.
  """
  @spec integer(String.t(), integer(), keyword()) :: integer()
  def integer(name, default, opts \\ []) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max)

    with value when is_binary(value) <- System.get_env(name),
         {parsed, ""} <- value |> String.trim() |> Integer.parse(),
         true <- parsed >= min,
         true <- is_nil(max) or parsed <= max do
      parsed
    else
      _missing_or_invalid -> default
    end
  end

  @doc """
  Reads a boolean setting.

  Accepts the spellings operators actually type. Anything else is treated as
  unset rather than as false, so a typo cannot silently disable a safety
  feature that defaults to on.
  """
  @spec boolean(String.t(), boolean()) :: boolean()
  def boolean(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case value |> String.trim() |> String.downcase() do
          truthy when truthy in ~w(true 1 yes on) -> true
          falsy when falsy in ~w(false 0 no off) -> false
          _unrecognised -> default
        end
    end
  end

  @doc """
  Reads a comma-separated list setting, dropping blank entries.

  Returns `nil` when the variable is unset so callers can tell "not configured"
  apart from "configured as empty".
  """
  @spec list(String.t()) :: [String.t()] | nil
  def list(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end
