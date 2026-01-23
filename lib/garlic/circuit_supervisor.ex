defmodule Garlic.CircuitSupervisor do
  alias Garlic.Circuit
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec start_circuit(Circuit.id(), binary) :: {:ok, pid} | {:error, any}
  def start_circuit(id, domain) do
    DynamicSupervisor.start_child(__MODULE__, {Circuit, [id, domain]})
  end

  @impl true
  def init(_init_arg) do
    Process.flag(:trap_exit, true)

    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
