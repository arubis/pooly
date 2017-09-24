defmodule Pooly.Server do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct [:sup, :worker_sup, :size, :workers, :monitors, :mfa]
    @type t :: %State{sup: pid, worker_sup: pid, size: non_neg_integer,
                      workers: list, monitors: list, mfa: {any, any, any}}
  end

  # API

  def start_link(sup, pool_config) do
    # FIXME Start off with named process (via opts = [name: @name])
    GenServer.start_link(__MODULE__, [sup, pool_config], name: __MODULE__)
  end

  def checkout do
    GenServer.call(__MODULE__, :checkout)
  end

  # Callbacks

  ## invoked upon GenServer.start_link/3
  ## stores the invoking (top-level) supervisor's pid in state, then inits pool
  def init([sup, pool_config]) when is_pid(sup) do
    monitors = :ets.new(:monitors, [:private])
    init(pool_config, %State{sup: sup, monitors: monitors})
  end

  ## Valid `pool_config`: `[mfa: {SampleWorker, :start_link, []}, size: 5]`
  ## Note it's an _ordered_ list, so we can h|t our way through it and know
  ## which keys to expect.
  ##
  ## Use this pattern to build up `state`.

  ## Pattern match for `mfa` option:
  def init([{:mfa, mfa}|tail], state),   do: init(tail, %{state | mfa: mfa})

  ## Pattern match for `size` options:
  def init([{:size, size}|tail], state), do: init(tail, %{state | size: size})

  ## (In theory, match for any other desired options here)

  ## Drop any other options:
  def init([_|tail], state),             do: init(tail, state)

  ## Options list empty, so assume state is built up
  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  def handle_call(:checkout, {from_pid, _ref}, %{workers: workers, monitors: monitors} = state) do
    case workers do
      [ worker|tail ] ->
        # exist un-checked-out workers in pool
        ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, ref})
        {:reply, worker, %{state | workers: tail}}

      [] ->
        # all workers checked out
        {:reply, :noproc, state}
    end
  end

  def handle_info(:start_worker_supervisor, state = %{sup: sup, mfa: mfa, size: size}) do
    {:ok, worker_sup} = Supervisor.start_child(sup, supervisor_spec(mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  # Private Functions

  defp supervisor_spec(mfa) do
    opts = [restart: :temporary]
    supervisor(Pooly.WorkerSupervisor, [mfa], opts)
  end

  defp prepopulate(size, sup), do: prepopulate(size, sup, [])
  defp prepopulate(size, _sup, workers) when size < 1, do: workers
  defp prepopulate(size, sup, workers) do
    prepopulate(size-1, sup, [new_worker(sup) | workers])
  end

  defp new_worker(sup) do
    # n.b. `sup` here receives worker_sup, so we're adding children
    # to `Pooly.WorkerSupervisor`. This has already had its child_spec
    # defined with start_child(supervisor_pid, child_spec) in
    # handle_info(:start_worker_supervisor) and uses a `:simple_one_for_one`
    # restart strategy, so the child spec is predefined. Instead, we use
    # the alternate start_child/2(supervisor, [args]) syntax.
    # Cf. h(Supervisor.start_child/2).
    {:ok, worker} = Supervisor.start_child(sup, [[]])
    worker
  end
end
