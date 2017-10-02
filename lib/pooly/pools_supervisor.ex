defmodule Pooly.PoolsSupervisor do
  use Supervisor

  def start_link, do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    # Only thing to do here is supply the restart strategy.
    # Pools to supervise will be supplied later by server.

    opts = [ strategy: :one_for_one ]
    supervise([], opts)
  end

end
