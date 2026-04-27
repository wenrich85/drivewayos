defmodule DrivewayOS.RateLimiterTest do
  @moduledoc """
  Unit-level coverage of the ETS-backed rate limiter. End-to-end
  integration with the auth LVs is covered in the LV tests
  (sign_in_live_test, etc.).
  """
  use ExUnit.Case, async: false

  alias DrivewayOS.RateLimiter

  setup do
    RateLimiter.reset_all()
    :ok
  end

  test "first N attempts are :ok" do
    for _ <- 1..5 do
      assert :ok == RateLimiter.check("k1", 5, 60_000)
    end
  end

  test "the (N+1)th attempt rate-limits + reports retry_after" do
    for _ <- 1..5 do
      assert :ok == RateLimiter.check("k2", 5, 60_000)
    end

    assert {:error, :rate_limited, retry_after_ms} =
             RateLimiter.check("k2", 5, 60_000)

    assert retry_after_ms > 0
    assert retry_after_ms <= 60_000
  end

  test "different keys have independent counters" do
    for _ <- 1..5 do
      assert :ok == RateLimiter.check("ka", 5, 60_000)
    end

    assert {:error, :rate_limited, _} = RateLimiter.check("ka", 5, 60_000)
    assert :ok == RateLimiter.check("kb", 5, 60_000)
  end

  test "reset/1 wipes a single key" do
    for _ <- 1..5, do: RateLimiter.check("kr", 5, 60_000)
    assert {:error, _, _} = RateLimiter.check("kr", 5, 60_000)

    RateLimiter.reset("kr")
    assert :ok == RateLimiter.check("kr", 5, 60_000)
  end

  test "expired entries fall out of the window" do
    # Tiny window so we can test expiry without sleeping much.
    assert :ok == RateLimiter.check("ke", 2, 50)
    assert :ok == RateLimiter.check("ke", 2, 50)
    assert {:error, _, _} = RateLimiter.check("ke", 2, 50)

    Process.sleep(80)
    assert :ok == RateLimiter.check("ke", 2, 50)
  end
end
