defmodule MicuPoker.RateLimiterTest do
  # Not async: the limiter owns one global ETS table and this suite toggles the
  # application-wide enable flag.
  use ExUnit.Case, async: false

  alias MicuPoker.RateLimiter

  setup do
    previous = Application.get_env(:micu_poker, :rate_limiting_enabled, true)
    Application.put_env(:micu_poker, :rate_limiting_enabled, true)
    RateLimiter.clear_all()

    on_exit(fn ->
      Application.put_env(:micu_poker, :rate_limiting_enabled, previous)
      RateLimiter.clear_all()
    end)

    %{key: {:test, System.unique_integer([:positive])}}
  end

  test "allows hits up to the limit and denies the next one", %{key: key} do
    assert {:allow, 2} = RateLimiter.hit(key, 3, 60_000)
    assert {:allow, 1} = RateLimiter.hit(key, 3, 60_000)
    assert {:allow, 0} = RateLimiter.hit(key, 3, 60_000)
    assert {:deny, retry_after} = RateLimiter.hit(key, 3, 60_000)
    assert retry_after > 0
  end

  test "budgets are independent per key" do
    first = {:test, System.unique_integer([:positive])}
    second = {:test, System.unique_integer([:positive])}

    assert {:allow, 0} = RateLimiter.hit(first, 1, 60_000)
    assert {:deny, _retry} = RateLimiter.hit(first, 1, 60_000)
    assert {:allow, 0} = RateLimiter.hit(second, 1, 60_000)
  end

  test "the budget resets in the next window", %{key: key} do
    now = System.system_time(:millisecond)
    window = 1_000
    window_start = div(now, window) * window

    assert {:allow, 0} = RateLimiter.hit(key, 1, window, window_start)
    assert {:deny, _retry} = RateLimiter.hit(key, 1, window, window_start + 500)
    assert {:allow, 0} = RateLimiter.hit(key, 1, window, window_start + window)
  end

  test "reset/1 clears every window for a key", %{key: key} do
    assert {:allow, 0} = RateLimiter.hit(key, 1, 60_000)
    assert {:deny, _retry} = RateLimiter.hit(key, 1, 60_000)

    RateLimiter.reset(key)

    assert {:allow, 0} = RateLimiter.hit(key, 1, 60_000)
  end

  test "count/2 reports hits in the current window", %{key: key} do
    assert RateLimiter.count(key, 60_000) == 0
    RateLimiter.hit(key, 10, 60_000)
    RateLimiter.hit(key, 10, 60_000)
    assert RateLimiter.count(key, 60_000) == 2
  end

  test "hits are allowed when limiting is disabled", %{key: key} do
    Application.put_env(:micu_poker, :rate_limiting_enabled, false)

    for _ <- 1..50, do: assert({:allow, _remaining} = RateLimiter.hit(key, 1, 60_000))
  end
end
