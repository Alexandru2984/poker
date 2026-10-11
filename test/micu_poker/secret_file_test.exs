defmodule MicuPoker.SecretFileTest do
  use ExUnit.Case, async: false

  alias MicuPoker.SecretFile

  @name "MICU_POKER_TEST_SECRET"

  setup do
    previous = System.get_env(@name)
    previous_file = System.get_env("#{@name}_FILE")
    System.delete_env(@name)
    System.delete_env("#{@name}_FILE")

    on_exit(fn ->
      restore_env(@name, previous)
      restore_env("#{@name}_FILE", previous_file)
    end)

    :ok
  end

  test "reads a direct secret" do
    System.put_env(@name, "direct-value")
    assert SecretFile.fetch!(@name) == "direct-value"
  end

  test "reads an absolute secret file and removes its final newline" do
    path = temporary_secret("file-value\n")
    System.put_env("#{@name}_FILE", path)
    assert SecretFile.fetch!(@name) == "file-value"
  end

  test "refuses ambiguous sources without exposing either value" do
    path = temporary_secret("file-value")
    System.put_env(@name, "direct-value")
    System.put_env("#{@name}_FILE", path)

    assert SecretFile.fetch(@name) == {:error, :ambiguous}
  end

  test "refuses relative paths, empty files, NUL bytes and oversized input" do
    System.put_env("#{@name}_FILE", "relative-secret")
    assert SecretFile.fetch(@name) == {:error, :unreadable_file}

    for value <- ["", <<"value", 0>>, :binary.copy("x", 65_537)] do
      path = temporary_secret(value)
      System.put_env("#{@name}_FILE", path)
      assert {:error, _reason} = SecretFile.fetch(@name)
    end
  end

  defp temporary_secret(contents) do
    path = Path.join(System.tmp_dir!(), "micu-poker-secret-#{System.unique_integer([:positive])}")
    File.write!(path, contents, [:binary, :exclusive])
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
