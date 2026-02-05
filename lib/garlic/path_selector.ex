defmodule Garlic.PathSelector do
  @moduledoc """
  Selects relay paths for circuit racing.

  Picks rendezvous point candidates and introduction points with
  diversity constraints (different /16 subnets, different routers).
  """

  alias Garlic.NetworkStatus

  @doc """
  Select `count` high-bandwidth relays suitable as rendezvous points.
  Ensures /16 subnet diversity among selected relays.
  """
  @spec select_rendezvous_relays(pos_integer()) :: [Garlic.Router.t()]
  def select_rendezvous_relays(count) do
    NetworkStatus.pick_fast_routers(count * 3)
    |> ensure_subnet_diversity(count)
  end

  @doc """
  Select up to `count` introduction points from an HS descriptor's list.
  Shuffles to avoid always hitting the same one first.
  """
  @spec select_intro_points([Garlic.IntroductionPoint.t()], pos_integer()) ::
          [Garlic.IntroductionPoint.t()]
  def select_intro_points(intro_points, count) do
    intro_points
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @doc """
  Build N diverse (rendezvous_relay, intro_point) pairs for racing.

  Each pair uses a different RP. Intro points are distributed across
  available ones (cycling if fewer intro points than count).
  """
  @spec build_race_paths(
          [Garlic.Router.t()],
          [Garlic.IntroductionPoint.t()],
          pos_integer()
        ) :: [{Garlic.Router.t(), Garlic.IntroductionPoint.t()}]
  def build_race_paths(rp_candidates, intro_points, count) do
    rps = Enum.take(rp_candidates, count)
    ips = Stream.cycle(intro_points)

    Enum.zip(rps, ips)
  end

  defp ensure_subnet_diversity(routers, count) do
    routers
    |> Enum.reduce({[], MapSet.new()}, fn router, {selected, subnets} ->
      subnet = subnet_key(router)

      if MapSet.member?(subnets, subnet) do
        {selected, subnets}
      else
        {[router | selected], MapSet.put(subnets, subnet)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.take(count)
  end

  defp subnet_key(%{ipv4: {a, b, _, _}}), do: {a, b}
  defp subnet_key(_), do: :unknown
end
