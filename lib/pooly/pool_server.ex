defmodule Pooly.PoolServer do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct pool_sup: nil, worker_sup: nil, monitors: nil, size: nil,
      workers: nil, name: nil, mfa: nil
    # untested:
    @type t :: %State{pool_sup: pid, worker_sup: pid, size: non_neg_integer,
                      workers: list, name: list, monitors: list, mfa: {any, any, any}}
  end

  # API

  def start_link(pool_sup, pool_config) do
    GenServer.start_link(__MODULE__, [pool_sup, pool_config], name: name(pool_config[:name]))
  end

  def checkout(pool_name) do
    GenServer.call(name(pool_name), :checkout)
  end

  def checkin(pool_name, worker_pid) do
    GenServer.cast(name(pool_name), {:checkin, worker_pid})
  end

  def status(pool_name) do
    GenServer.call(name(pool_name), :status)
  end

  def terminate(_reason, _state), do: :ok

  # Callbacks

  def init([pool_sup, pool_config]) when is_pid(pool_sup) do
    Process.flag(:trap_exit, true)
    monitors = :ets.new(:monitors, [:private])
    init(pool_config, %State{pool_sup: pool_sup, monitors: monitors})
  end

  ## Valid `pool_config`: `[name, mfa: {SampleWorker, :start_link, []}, size: 5]`
  ## Note it's an _ordered_ list, so we can h|t our way through it and know
  ## which keys to expect.
  ##
  ## Use this pattern to build up `state`.

  ## Pattern match for `name` option:
  def init([{:name, name}|tail], state), do: init(tail, %{state | name: name})
  ## Pattern match for `mfa` option:
  def init([{:mfa, mfa}|tail], state),   do: init(tail, %{state | mfa: mfa})
  ## Pattern match for `size` options:
  def init([{:size, size}|tail], state), do: init(tail, %{state | size: size})

  ## Options list empty, so assume state is built up
  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  ## Drop any other options:
  def init([_|tail], state),             do: init(tail, state)

  def handle_call(:checkout, {from_pid, _ref}, %{workers: workers, monitors: monitors} = state) do
    case workers do
      [worker|tail] ->
        # exist un-checked-out workers in pool
        ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, ref})
        {:reply, worker, %{state | workers: tail}}

      [] ->
        # all workers checked out
        {:reply, :noproc, state}
    end
  end

  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
    {:reply, {length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker}, %{workers: workers, monitors: monitors} = state) do
    case :ets.lookup(monitors, worker) do
      [{pid, ref}] ->
        # TODO this looks like a prime candidate to refactor using `with`
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        {:noreply, %{state | workers: [pid|workers]}}
      [] ->
        {:noreply, state}
    end
  end

  def handle_info(:start_worker_supervisor, state = %{pool_sup: pool_sup, name: name, mfa: mfa, size: size}) do
    {:ok, worker_sup} = Supervisor.start_child(pool_sup, supervisor_spec(name, mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  def handle_info({:DOWN, ref, _, _, _}, state = %{monitors: monitors, workers: workers}) do
    case :ets.match(monitors, {:"$1", ref}) do
      [[pid]] ->
        true = :ets.delete(monitors, pid)
        new_state = %{state | workers: [pid|workers]}
        {:noreply, new_state}

      [[]] ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state = %{monitors: monitors, workers: workers, pool_sup: pool_sup}) do
    case :ets.lookup(monitors, pid) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        new_state = %{state | workers: [new_worker(pool_sup)|workers]}
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, worker_sup, reason}, state = %{worker_sup: worker_sup}) do
    {:stop, reason, state}
  end

  # Private functions

  defp name(pool_name), do: :"#{pool_name}Server"

  defp prepopulate(size, sup), do: prepopulate(size, sup, [])
  defp prepopulate(size, _sup, workers) when size < 1, do: workers
  defp prepopulate(size, sup, workers) do
    prepopulate(size-1, sup, [new_worker(sup) | workers])
  end

  defp new_worker(sup) do
    {:ok, worker} = Supervisor.start_child(sup, [[]])
    worker
  end

  defp supervisor_spec(name, mfa) do
    opts = [id: name <> "WorkerSupervisor", restart: :temporary]
    supervisor(Pooly.WorkerSupervisor, [self(), mfa], opts)
  end

end
