defmodule MicuPokerWeb.Plugs.RateLimitTest do
  use MicuPokerWeb.ConnCase, async: false

  alias MicuPoker.RateLimiter

  setup do
    previous = Application.get_env(:micu_poker, :rate_limiting_enabled, true)
    Application.put_env(:micu_poker, :rate_limiting_enabled, true)
    RateLimiter.clear_all()

    on_exit(fn ->
      Application.put_env(:micu_poker, :rate_limiting_enabled, previous)
      RateLimiter.clear_all()
    end)

    :ok
  end

  defp from_ip(conn, ip), do: Map.put(conn, :remote_ip, ip)

  test "room creation is capped per client address", %{conn: conn} do
    params = %{"room" => %{"name" => "Rate Limit Table"}}

    responses =
      for _ <- 1..12 do
        conn
        |> recycle()
        |> from_ip({203, 0, 113, 10})
        |> post(~p"/rooms", params)
      end

    assert Enum.any?(responses, &(&1.status == 429))
  end

  test "a throttled client gets a retry-after header", %{conn: conn} do
    params = %{"room" => %{"name" => "Retry After Table"}}

    throttled =
      Enum.find_value(1..12, fn _ ->
        response =
          conn
          |> recycle()
          |> from_ip({203, 0, 113, 11})
          |> post(~p"/rooms", params)

        if response.status == 429, do: response
      end)

    assert throttled
    assert [retry_after] = get_resp_header(throttled, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "one client's budget does not affect another address", %{conn: conn} do
    params = %{"room" => %{"name" => "Isolated Table"}}

    for _ <- 1..12 do
      conn |> recycle() |> from_ip({203, 0, 113, 12}) |> post(~p"/rooms", params)
    end

    fresh = conn |> recycle() |> from_ip({203, 0, 113, 13}) |> post(~p"/rooms", params)

    assert fresh.status != 429
  end

  test "the public API answers 429 as JSON rather than redirecting", %{conn: conn} do
    responses =
      for _ <- 1..130 do
        conn |> recycle() |> from_ip({203, 0, 113, 14}) |> get(~p"/api/rooms")
      end

    throttled = Enum.find(responses, &(&1.status == 429))

    assert throttled
    assert json_response(throttled, 429)["error"] == "rate_limited"
  end

  test "/health is never rate limited so uptime checks keep working", %{conn: conn} do
    responses =
      for _ <- 1..150 do
        conn |> recycle() |> from_ip({203, 0, 113, 15}) |> get(~p"/health")
      end

    assert Enum.all?(responses, &(&1.status == 200))
  end
end
