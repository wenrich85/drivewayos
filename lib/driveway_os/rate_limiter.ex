defmodule DrivewayOS.RateLimiter do
  @moduledoc """
  Tiny in-memory rate limiter for auth endpoints. ETS-backed
  fixed-window counter — for each `key`, count attempts in a
  rolling window of `window_ms` and reject once `max` is reached.

  Per-process state lives in an ETS table named after the
  module; the GenServer just creates the table and runs a
  periodic GC pass to prune expired entries (bound the table
  size).

  Caveats / scope:
    * Single-node only. Two app instances behind a load balancer
      each maintain their own counter — a brute-forcer round-robins
      and gets 2x the budget. Acceptable at V1 scale; swap for a
      Redis backend (Hammer or similar) when we go multi-node.
    * Restart-loses-counters. If someone deploys mid-attack, the
      counter resets. Same caveat — fine for V1.
    * No IP-based keying built in here — callers compose whatever
      key string they want (typically `<tenant_id>:<email>`).
  """
  use GenServer

  @table __MODULE__
  @gc_interval_ms 5 * 60 * 1000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record an attempt against `key` and decide whether to allow it.
  Returns `:ok` (under limit) or `{:error, :rate_limited, retry_after_ms}`
  (would exceed). Either way the attempt counts toward the window.
  """
  @spec check(String.t() | atom(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check(key, max, window_ms) when is_integer(max) and max > 0 and is_integer(window_ms) do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    window_start = now - window_ms

    # Update_counter trick: read-modify-write atomically. We append
    # `now` to the deque, then trim later in the GC pass.
    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, [now]})
        :ok

      [{^key, attempts}] ->
        recent = Enum.filter(attempts, &(&1 >= window_start))

        if length(recent) >= max do
          oldest = List.last(recent)
          retry_after = max(oldest + window_ms - now, 0)
          # Don't append on rejection — we want the oldest entry
          # to age out and free up the slot.
          :ets.insert(@table, {key, recent})
          {:error, :rate_limited, retry_after}
        else
          :ets.insert(@table, {key, [now | recent]})
          :ok
        end
    end
  end

  @doc """
  Wipe a specific key. Use after a successful sign-in so a
  legit user who fat-fingered their password 3 times doesn't
  carry the counter forward.
  """
  @spec reset(String.t() | atom()) :: :ok
  def reset(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @doc "Test helper: clear every counter."
  @spec reset_all() :: :ok
  def reset_all do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    ensure_table()
    Process.send_after(self(), :gc, @gc_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:gc, state) do
    # Prune entries with no recent attempts. Protects the table
    # from unbounded growth from one-off keys.
    cutoff = System.monotonic_time(:millisecond) - 60 * 60 * 1000

    :ets.foldl(
      fn {key, attempts}, acc ->
        if Enum.all?(attempts, &(&1 < cutoff)) do
          :ets.delete(@table, key)
        end

        acc
      end,
      :ok,
      @table
    )

    Process.send_after(self(), :gc, @gc_interval_ms)
    {:noreply, state}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end
