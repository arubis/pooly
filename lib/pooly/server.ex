defmodule Pooly.Server do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct [:sup, :worker_sup, :size, :workers, :mfa]
    @type t :: %State{sup: pid, worker_sup: pid, size: non_neg_integer,
                      workers: _TODO, mfa: {any, any, any}}
  end

  # API

  def start_link(sup, pool_config) do
    # FIXME Start off with named process (via opts = [name: @name])
    GenServer.start_link(__MODULE__, [sup, pool_config], name: __MODULE__)
  end

  # Callbacks

  ## invoked upon GenServer.start_link/3
  ## stores the invoking (top-level) supervisor's pid in state, then inits pool
  def init([sup, pool_config]) when is_pid(sup) do
    init(pool_config, %State{sup: sup})
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

  def handle_info(:start_worker_supervisor, state = %{sup: sup, mfa: mfa, size: size}) do
    {:ok, worker_sup} = Supervisor.start_child(sup, supervisor_spec(mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  # Private Functions

  defp supervisor_spec(mfa) do
    opts = [restart: :temporary]
    supervise(Pooly.WorkerSupervisor, [mfa], opts)
  end
end