defmodule Pooly do
  use Application

  @timeout 5000

  def start(_type, _args) do
    pools_config =
      [
        [name: "Pool1",
         mfa: {SampleWorker, :start_link, []},
         size: 2,
         max_overflow: 2,
        ],
        [name: "Pool2",
         mfa: {SampleWorker, :start_link, []},
         size: 3,
         max_overflow: 0,
        ],
        [name: "Pool3",
         mfa: {SampleWorker, :start_link, []},
         size: 4,
         max_overflow: 0
        ],
      ]

    start_pools(pools_config)
  end

  def start_pools(pools_config), do: Pooly.Supervisor.start_link(pools_config)

  def checkout(pool_name, block \\ true, timeout \\ @timeout) do
    Pooly.Server.checkout(pool_name, block, timeout)
  end

  def checkin(pool_name, worker_pid), do: Pooly.Server.checkin(pool_name, worker_pid)

  @doc ~S"""
  Checks out a worker, hands its pid to the given function,
  then checks the worker back in when finished.

  ## Examples:

      iex> Pooly.transaction("Pool1",
      ...>   fn(worker) ->
      ...>     send(self(), {:hello, worker})
      ...>   end)
      ...>
      ...> receive do
      ...>   {:hello, pid} when is_pid(pid) ->
      ...>     :ok
      ...>   _ ->
      ...>     :error
      ...> end
      :ok

  """
  def transaction(pool_name, fun, timeout \\ @timeout) do
    Pooly.Server.transaction(pool_name, fun, timeout)
  end
  def status(pool_name), do: Pooly.Server.status(pool_name)
end
