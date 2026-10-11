defmodule MicuPoker.SecretFile do
  @moduledoc """
  Reads a secret from an environment variable or its `_FILE` counterpart.

  Production uses systemd credentials, which expose root-managed files below
  `%d`. Refusing ambiguous or malformed input keeps a stale environment value
  from silently overriding a rotated credential.
  """

  @max_bytes 65_536

  @type result :: {:ok, binary()} | :missing | {:error, atom()}

  @spec fetch(binary()) :: result()
  def fetch(name) when is_binary(name) do
    direct = present(System.get_env(name))
    path = present(System.get_env("#{name}_FILE"))

    case {direct, path} do
      {nil, nil} -> :missing
      {_value, _path} when not is_nil(direct) and not is_nil(path) -> {:error, :ambiguous}
      {value, nil} -> normalize(value)
      {nil, path} -> read(path)
    end
  end

  @spec fetch!(binary()) :: binary()
  def fetch!(name) do
    case fetch(name) do
      {:ok, value} -> value
      :missing -> raise ArgumentError, "secret #{name} is missing"
      {:error, reason} -> raise ArgumentError, "secret #{name} is invalid: #{reason}"
    end
  end

  defp read(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, value} <- File.read(path) do
      normalize(value)
    else
      _error -> {:error, :unreadable_file}
    end
  end

  defp normalize(value) when byte_size(value) <= @max_bytes do
    value = value |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    cond do
      value == "" -> {:error, :empty}
      not String.valid?(value) -> {:error, :invalid_utf8}
      :binary.match(value, <<0>>) != :nomatch -> {:error, :nul_byte}
      true -> {:ok, value}
    end
  end

  defp normalize(_value), do: {:error, :too_large}

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
