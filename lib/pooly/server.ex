defmodule Pooly.Server do
  use GenServer
  import Supervisor.Spec

  # API

  def start_link(pools_config) do
    GenServer.start_link(__MODULE__, pools_config, name: __MODULE__)
  end

  # FIXME interpolation into atom here smells a little off.
  # However, note that this is representative of someone else's mistakes,
  # and is a reminder that GenServer.call/3's first argument _must be an atom_.
  def checkout(pool_name), do: GenServer.call(:"#{pool_name}Server", :checkout)
  def checkin(pool_name, worker_pid), do: GenServer.cast(:"#{pool_name}Server", {:checkin, worker_pid})
  def status(pool_name), do: GenServer.call(:"#{pool_name}Server", :status)

  # Callbacks

  ## invoked upon GenServer.start_link/3
  ## iterates through the configuration, sending `:start_pool` to itself
  def init(pools_config) do
    pools_config |> Enum.each(fn(pool_config) ->
      send(self(), {:start_pool, pool_config})
    end)

    {:ok, pools_config}
  end

  def handle_info({:start_pool, pool_config}, state) do
    {:ok, _pool_sup} = Supervisor.start_child(Pooly.PoolsSupervisor, supervisor_spec(pool_config))
    {:noreply, state}
  end

  # Private Functions

  defp supervisor_spec(pool_config) do
    # Supervisor spec must be unique, so vary the ID field:
    opts = [id: :"#{pool_config[:name]}Supervisor"]
    supervisor(Pooly.PoolSupervisor, [pool_config], opts)
  end

end
