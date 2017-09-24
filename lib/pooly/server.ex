defmodule Pooly.Server do
  use GenServer
  import Supervisor.Spec

  # API

  def start_link(sup, pool_config) do
    GenServer.start_link(__MODULE__, [sup, pool_config], name: __MODULE__)
  end

end
