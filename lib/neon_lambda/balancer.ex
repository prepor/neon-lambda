defmodule NeonLambda.Balancer do
  require Logger
  use GenServer

  @type worker :: %{
          type: :primary | :replica,
          port: integer(),
          status: :pending | :ready,
          worker: pid(),
          dispatcher: pid() | nil
        }
  @type state :: %{workers: %{reference() => worker()}, init_port: integer()}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end

  def handle(id, req) do
    :telemetry.span([:neon, :handle], %{}, fn ->
      {:ok, pid} = random_worker()

      res =
        case GenServer.call(pid, {:request, id, req}) do
          {:ok, res} ->
            res

          {:error, :write_in_replica} ->
            Logger.info("Write in replica, redirect to primary")
            {:ok, pid} = primary_worker()
            {:ok, res} = GenServer.call(pid, {:request, id, req})
            res
        end

      {res, %{}}
    end)
  end

  def deploy(lambda) do
    id =
      :crypto.hash(:sha256, :crypto.strong_rand_bytes(32))
      |> Base.encode16(case: :lower)

    {:ok, pid} = primary_worker()
    :ok = GenServer.call(pid, {:deploy, id, lambda})
    "http://localhost:3010/#{id}/"
  end

  def scale_up() do
    GenServer.call(__MODULE__, :scale_up)
  end

  def scale_down() do
    GenServer.call(__MODULE__, :scale_down)
  end

  def worker_ready(ref, pid) do
    GenServer.cast(__MODULE__, {:worker_ready, ref, pid})
  end

  defp random_worker() do
    GenServer.call(__MODULE__, :random_worker)
  end

  defp primary_worker() do
    GenServer.call(__MODULE__, :primary_worker)
  end

  @impl true
  def init(_args) do
    state = %{workers: %{}, init_port: Application.get_env(:neon_lambda, :init_port)}
    {:ok, state, {:continue, []}}
  end

  @impl true
  def handle_continue(_, state) do
    {:noreply, add_worker(:primary, state)}
  end

  @impl true
  def handle_call(:random_worker, _from, %{workers: workers} = state) do
    active_workers = workers |> Map.values() |> Enum.filter(&(&1.status == :ready))

    if Enum.empty?(active_workers) do
      {:reply, {:error, :no_active_workers}, state}
    else
      {:reply, {:ok, Enum.random(active_workers).dispatcher}, state}
    end
  end

  def handle_call(:primary_worker, _from, %{workers: workers} = state) do
    primary =
      workers
      |> Map.values()
      |> Enum.find(fn %{status: status, type: type} ->
        status == :ready and type == :primary
      end)

    if primary do
      {:reply, {:ok, primary.dispatcher}, state}
    else
      {:reply, {:error, :no_primary_workers}, state}
    end
  end

  def handle_call(:status, _from, %{workers: workers} = state) do
    {:reply,
     workers |> Map.values() |> Enum.map(fn w -> Map.take(w, [:status, :port, :type]) end), state}
  end

  def handle_call(:scale_up, _from, state) do
    {:reply, :ok, add_worker(:replica, state)}
  end

  def handle_call(:scale_down, _from, state) do
    {:reply, :ok, remove_worker(state)}
  end

  @impl true
  def handle_cast({:worker_ready, ref, pid}, %{workers: workers} = state) do
    workers =
      Map.update!(workers, ref, fn worker -> %{worker | status: :ready, dispatcher: pid} end)

    broadcast_updated()
    {:noreply, %{state | workers: workers}}
  end

  @workers_supervisor NeonLambda.Workers
  defp add_worker(type, %{workers: workers, init_port: init_port} = state) do
    port = next_free_port(init_port, workers)
    ref = make_ref()

    {:ok, pid} =
      DynamicSupervisor.start_child(
        @workers_supervisor,
        {NeonLambda.Worker,
         type: type,
         tenant_id: Application.get_env(:neon_lambda, :tenant_id),
         timeline_id: Application.get_env(:neon_lambda, :timeline_id),
         pg_bin: Application.get_env(:neon_lambda, :pg_bin),
         ctl_bin: Application.get_env(:neon_lambda, :ctl_bin),
         http_port: port,
         pg_port: port + 1,
         balancer_ref: ref}
      )

    broadcast_updated()

    %{
      state
      | workers:
          Map.put(workers, ref, %{
            type: type,
            port: port,
            status: :pending,
            worker: pid,
            dispatcher: nil
          })
    }
  end

  defp remove_worker(%{workers: workers} = state) do
    replica_workers =
      workers
      |> Enum.filter(fn {_, %{type: type}} -> type == :replica end)

    if Enum.empty?(replica_workers) do
      state
    else
      {ref, %{worker: pid}} =
        replica_workers |> Enum.random()

      DynamicSupervisor.terminate_child(@workers_supervisor, pid)
      broadcast_updated()
      %{state | workers: Map.delete(workers, ref)}
    end
  end

  defp next_free_port(port, workers) do
    if Enum.any?(workers, fn {_, %{port: p}} -> p == port end) do
      next_free_port(port + 2, workers)
    else
      port
    end
  end

  defp broadcast_updated() do
    Phoenix.PubSub.broadcast(NeonLambda.PubSub, "balancer", :updated)
  end
end
