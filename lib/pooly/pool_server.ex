defmodule Pooly.PoolServer do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct pool_sup: nil,
      worker_sup: nil,
      monitors: nil,
      size: nil,
      workers: nil,
      name: nil,
      mfa: nil,
      max_overflow: nil,
      overflow: nil,
      waiting: nil
    @type t :: %State{pool_sup: pid,
                      worker_sup: pid,
                      size: non_neg_integer,
                      workers: list,
                      name: list,
                      monitors: list,
                      mfa: {any, any, any},
                      max_overflow: non_neg_integer,
                      overflow: non_neg_integer,
                      waiting: any,}
  end

  # API

  def start_link(pool_sup, pool_config) do
    GenServer.start_link(__MODULE__, [pool_sup, pool_config], name: name(pool_config[:name]))
  end

  def checkout(pool_name, block, timeout) do
    GenServer.call(name(pool_name), {:checkout, block}, timeout)
  end

  def checkin(pool_name, worker_pid) do
    GenServer.cast(name(pool_name), {:checkin, worker_pid})
  end

  def status(pool_name) do
    GenServer.call(name(pool_name), :status)
  end

  # Callbacks

  def init([pool_sup, pool_config]) when is_pid(pool_sup) do
    Process.flag(:trap_exit, true)
    monitors = :ets.new(:monitors, [:private])
    waiting  = :queue.new
    state    = %State{pool_sup: pool_sup,
                      monitors: monitors,
                      waiting: waiting,
                      overflow: 0}

    init(pool_config, state)
  end

  ## Valid `pool_config`: `[name, mfa: {module, function, [args]}, size: 5]`
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
  def init([{:max_overflow, max_overflow}|tail], state), do: init(tail, %{state | max_overflow: max_overflow})
  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end
  ## Drop any other options:
  def init([_|tail], state), do: init(tail, state)

  ## this may be redundant; drop next handle_call(:checkout, ...)?

  def handle_call({:checkout, block}, {from_pid, _ref}, state) do
    %{worker_sup: worker_sup,
      workers: workers,
      monitors: monitors,
      waiting: waiting,
      overflow: overflow,
      max_overflow: max_overflow} = state

    case workers do
      [worker|tail] ->
        ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, ref})
        {:reply, worker, %{state | workers: tail}}

      [] when max_overflow > 0 and overflow < max_overflow ->
        # pretty sure this doesn't work without defining new_worker/2...
        {worker, ref} = new_worker(worker_sup, from_pid)
        true = :ets.insert(monitors, {worker, ref})
        {reply, worker, %{state | overflow: overflow+1}}

      [] when block == true ->
        ref = Process.monitor(from_pid)
        waiting = :queue.in({from, ref}, waiting)
        {:noreply, %{state | waiting: waiting}, :infinity}

      [] ->
        {:reply, :full, state}
    end
  end

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
    {:reply, {state_name(state), length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker}, %{workers: workers, monitors: monitors} = state) do
    case :ets.lookup(monitors, worker) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        new_state = handle_checkin(pid, state)
        {:noreply, new_state}

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

  ### Pattern matching order matters!!! Fought confusion for a while here.
  def handle_info({:EXIT, worker_sup, reason}, state = %{worker_sup: worker_sup}) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, pid, _reason}, state = %{monitors: monitors, workers: workers, pool_sup: pool_sup}) do
    case :ets.lookup(monitors, pid) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        new_state = handle_worker_exit(pid, state)
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def terminate(_reason, _state), do: :ok

  # Private functions

  defp name(pool_name), do: :"#{pool_name}Server"

  defp prepopulate(size, sup), do: prepopulate(size, sup, [])
  defp prepopulate(size, _sup, workers) when size < 1, do: workers
  defp prepopulate(size, sup, workers) do
    prepopulate(size-1, sup, [new_worker(sup) | workers])
  end

  defp new_worker(sup) do
    {:ok, worker} = Supervisor.start_child(sup, [[]])
    Process.link(worker)   # Pointed out in repo; didn't see ref here in text
    worker
  end

  ### revisit?
  defp supervisor_spec(name, mfa) do
    # NOTE: The reason this is set to temporary is because the WorkerSupervisor
    #       is started by the PoolServer. They restart in concert due to the
    #       `Process.link` to PoolServer in WorkerSupervisor.
    opts = [id: name <> "WorkerSupervisor", shutdown: 10000, restart: :temporary]
    supervisor(Pooly.WorkerSupervisor, [self(), mfa], opts)
  end

  # might want to make this public (`def` not `defp`)
  defp handle_checkin(pid, state) do
    %{worker_sup: worker_sup,
      workers: workers,
      monitors: monitors,
      waiting: waiting,
      overflow: overflow} = state

    case :queue.out(waiting) do
      {{:value, {from, ref}}, tail} ->
        true = :ets.insert(monitors, {pid, ref})
        GenServer.reply(from, pid)
        %{state | waiting: tail}

      {:empty, empty} when overflow > 0 ->
        :ok = dismiss_worker(worker_sup, pid)
        %{state | waiting: empty, overflow: overflow-1}

      {:empty, empty} ->
        %{state | waiting: empty, workers: [pid|workers], overflow: 0}
    end

    ### before handling queue, this was:
    # if overflow > 0 do
    #   :ok = dismiss_worker(worker_sup, pid)
    #   %{state | waiting: empty, overflow: overflow-1}
    # else
    #   %{state | waiting: empty, workers: [pid|workers], overflow: 0}
    # end
  end

  defp dismiss_worker(sup, pid) do
    true = Process.unlink(pid)
    Supervisor.terminate_child(sup, pid)
  end

  defp handle_worker_exit(pid, state) do
    %{worker_sup: worker_sup,
      workers: workers,
      monitors: monitors,
      waiting: waiting,
      overflow: overflow} = state

    case :queue.out(waiting) do
      {{:value, {from, ref}}, tail} ->
        new_worker = new_worker(worker_sup)
        true = :ets.insert(monitors, {new_worker, ref})
        GenServer.reply(from, new_worker)
        %{state | waiting: tail}

      {:empty, empty} when overflow > 0 ->
        %{state | overflow: overflow-1, waiting: empty}

      {:empty, empty} ->
        workers = [new_worker(worker_sup) | workers]
        %{state | workers: workers, waiting: empty}
    end

    ### before handling queue, this was:
    # if overflow > 0 do
    #   %{state | overflow: overflow-1}
    # else
    #   %{state | workers: [new_worker(worker_sup)|workers]}
    # end
  end

  defp state_name(%State{overflow: overflow, max_overflow: max_overflow, workers: workers}) when overflow < 1 do
    case length(workers) == 0 do
      true ->
        if max_overflow < 1 do
          :full
        else
          :overflow
        end
      false ->
        :ready
    end
  end

  defp state_name(%State{overflow: max_overflow, max_overflow: max_overflow}), do: :full
  defp state_name(_state), do: :overflow

end
