defmodule Garlic.NetworkStatusTest do
  use ExUnit.Case

  import Garlic.NetworkStatus
  import DateTime, only: [to_unix: 1]
  alias Garlic.NetworkStatus

  test "time period" do
    fake_time = to_unix(~U[2016-04-13 11:00:00Z])

    assert get_time_period_num(%NetworkStatus{}, fake_time) == 16_903

    fake_time = fake_time + 3599

    assert get_time_period_num(%NetworkStatus{}, fake_time) == 16_903
  end

  test "shared random value" do
    network_status = %NetworkStatus{
      current_shared_random: :crypto.strong_rand_bytes(32),
      previous_shared_random: :crypto.strong_rand_bytes(32)
    }

    srv =
      network_status
      |> Map.put(:valid_after, to_unix(~U[1985-10-26 00:00:00Z]))
      |> Map.put(:fresh_until, to_unix(~U[1985-10-26 01:00:00Z]))
      |> get_shared_random()

    assert srv == network_status.previous_shared_random

    srv =
      network_status
      |> Map.put(:valid_after, to_unix(~U[1985-10-26 11:00:00Z]))
      |> Map.put(:fresh_until, to_unix(~U[1985-10-26 12:00:00Z]))
      |> get_shared_random()

    assert srv == network_status.previous_shared_random

    srv =
      network_status
      |> Map.put(:valid_after, to_unix(~U[1985-10-26 12:00:00Z]))
      |> Map.put(:fresh_until, to_unix(~U[1985-10-26 13:00:00Z]))
      |> get_shared_random()

    assert srv == network_status.current_shared_random

    srv =
      network_status
      |> Map.put(:valid_after, to_unix(~U[1985-10-26 23:00:00Z]))
      |> Map.put(:fresh_until, to_unix(~U[1985-10-27 00:00:00Z]))
      |> get_shared_random()

    assert srv == network_status.current_shared_random

    srv =
      network_status
      |> Map.put(:valid_after, to_unix(~U[1985-10-27 00:00:00Z]))
      |> Map.put(:fresh_until, to_unix(~U[1985-10-27 01:00:00Z]))
      |> get_shared_random()

    assert srv == network_status.previous_shared_random
  end
end
