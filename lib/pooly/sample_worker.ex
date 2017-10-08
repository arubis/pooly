defmodule SampleWorker do
  use GenServer

  def start_link(_), do:  GenServer.start_link(__MODULE__, :ok, [])

  def stop(pid), do: GenServer.call(pid, :stop)

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}
end
