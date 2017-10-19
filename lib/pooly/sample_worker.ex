defmodule SampleWorker do
  use GenServer

  def start_link(_), do:  GenServer.start_link(__MODULE__, :ok, [])

  def stop(pid), do: GenServer.call(pid, :stop)

  def work_for(pid, duration) do
    GenServer.cast(pid, {:work_for, duration})
  end

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}

  def handle_cast({:work_for, duration}, state) do
    :timer.sleep(duration)
    {:stop, :normal, state}
  end

end
