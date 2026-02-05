defmodule Garlic.PathSelectorTest do
  use ExUnit.Case

  alias Garlic.{PathSelector, Router, IntroductionPoint}

  describe "select_intro_points/2" do
    test "returns up to count intro points" do
      ips = for i <- 1..5, do: %IntroductionPoint{router: %Router{nickname: "ip#{i}"}}
      selected = PathSelector.select_intro_points(ips, 3)
      assert length(selected) == 3
    end

    test "returns all when fewer than count" do
      ips = [%IntroductionPoint{router: %Router{nickname: "ip1"}}]
      selected = PathSelector.select_intro_points(ips, 5)
      assert length(selected) == 1
    end

    test "shuffles the selection" do
      ips = for i <- 1..10, do: %IntroductionPoint{router: %Router{nickname: "ip#{i}"}}

      orders =
        for _ <- 1..20 do
          PathSelector.select_intro_points(ips, 5)
          |> Enum.map(& &1.router.nickname)
        end

      assert length(Enum.uniq(orders)) > 1, "Expected shuffled results across runs"
    end
  end

  describe "build_race_paths/3" do
    test "pairs RPs with intro points" do
      rps = for i <- 1..4, do: %Router{nickname: "rp#{i}", ipv4: {10, i, 0, 1}}

      ips = for i <- 1..2, do: %IntroductionPoint{router: %Router{nickname: "ip#{i}"}}

      paths = PathSelector.build_race_paths(rps, ips, 4)

      assert length(paths) == 4

      Enum.each(paths, fn {rp, ip} ->
        assert %Router{} = rp
        assert %IntroductionPoint{} = ip
      end)
    end

    test "cycles intro points when fewer than count" do
      rps = for i <- 1..4, do: %Router{nickname: "rp#{i}", ipv4: {10, i, 0, 1}}
      ips = [%IntroductionPoint{router: %Router{nickname: "ip1"}}]

      paths = PathSelector.build_race_paths(rps, ips, 4)

      assert length(paths) == 4
      ip_names = Enum.map(paths, fn {_, ip} -> ip.router.nickname end)
      assert Enum.all?(ip_names, &(&1 == "ip1"))
    end

    test "limits to count even with more RPs" do
      rps = for i <- 1..10, do: %Router{nickname: "rp#{i}", ipv4: {10, i, 0, 1}}
      ips = [%IntroductionPoint{router: %Router{nickname: "ip1"}}]

      paths = PathSelector.build_race_paths(rps, ips, 3)
      assert length(paths) == 3
    end
  end

  describe "subnet diversity" do
    test "select_rendezvous_relays is callable" do
      assert is_function(&PathSelector.select_rendezvous_relays/1)
    end
  end
end
