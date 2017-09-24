defmodule Pooly.WorkerSupervisor do
  use Supervisor

  # API

  def start_link({_module,_function,_args} = mfa) do
    Supervisor.start_link(__MODULE__, mfa)
  end

  # Callbacks

  def init({m,f,a} = x) do
    worker_opts = [restart: :permanent,
                   function: f]

    children = [worker(m, a, worker_opts)]
    # worker/3 is Supervisor.Spec.worker/3
    # Supervisor.Spec is imported by Supervisor by default

    opts     = [strategy: :simple_one_for_one,
                max_restarts: 5,
                max_seconds: 5]

    # Supervisor.Spec.supervise/2
    supervise(children, opts)
  end
end
