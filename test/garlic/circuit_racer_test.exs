defmodule Garlic.CircuitRacerTest do
  use ExUnit.Case

  alias Garlic.CircuitRacer

  describe "module" do
    setup do
      Code.ensure_loaded!(CircuitRacer)
      :ok
    end

    test "exports race/2" do
      assert function_exported?(CircuitRacer, :race, 2)
    end

    test "exports build_lane/5" do
      assert function_exported?(CircuitRacer, :build_lane, 5)
    end
  end

  describe "race/2 without network" do
    @tag timeout: 30_000
    test "returns error for unreachable hidden service" do
      # Valid base32 format but nonexistent service
      domain = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion"

      result = CircuitRacer.race(domain, count: 1, timeout: 10_000)
      assert {:error, _reason} = result
    end
  end
end
