defmodule MicuPoker.RateLimiter do
  @moduledoc """
  Fixed-window rate limiter backed by a public ETS table.

  Counters live in ETS so `hit/3` runs in the calling process with no message
  passing, which keeps hot paths (every HTTP request, every socket connect) off
  a single GenServer mailbox. The owning process only creates the table and
  sweeps expired windows so memory cannot grow without bound.

  Windows are fixed rather than sliding: a key is allowed `limit` hits per
  `window_ms` slot. That over-admits at most `2 * limit` across a slot boundary,
  which is a fine trade for abuse control and costs a single atomic counter
  update per call.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval_ms :timer.minutes(2)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records a hit for `key` and reports whether it is within budget.

  Returns `{:allow, remaining}` or `{:deny, retry_after_ms}`.
  """
  def hit(key, limit, window_ms, now \\ System.system_time(:millisecond))
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    if enabled?() do
      window_start = div(now, window_ms) * window_ms
      expires_at = window_start + window_ms
      counter_key = {key, window_start}

      count = :ets.update_counter(@table, counter_key, {2, 1}, {counter_key, 0, expires_at})

      if count > limit do
        {:deny, expires_at - now}
      else
        {:allow, limit - count}
      end
    else
      {:allow, limit}
    end
  rescue
    # The table only disappears if the limiter is not running (for example in an
    # isolated unit test). Failing open is better than failing every request.
    ArgumentError -> {:allow, limit}
  end

  @doc """
  Whether limits are enforced. Disabled by default in tests so that unrelated
  suites do not share and exhaust each other's budgets.
  """
  def enabled?, do: Application.get_env(:micu_poker, :rate_limiting_enabled, true)

  @doc """
  Returns how many hits `key` has recorded in its current window.
  """
  def count(key, window_ms, now \\ System.system_time(:millisecond)) do
    window_start = div(now, window_ms) * window_ms

    case :ets.lookup(@table, {key, window_start}) do
      [{_key, count, _expires_at}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Drops every recorded window for `key`, e.g. after a successful login.
  """
  def reset(key) do
    :ets.match_delete(@table, {{key, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def clear_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.system_time(:millisecond))
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp sweep(now) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
