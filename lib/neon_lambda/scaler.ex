defmodule NeonLambda.Scaler do
  use GenServer

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end

  def set(v) do
    GenServer.call(__MODULE__, {:set, v})
  end

  @seconds 5
  @req_threashold 1000
  @max_replicas 10

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    :ok = :telemetry.attach("neon-scaler", [:neon, :handle, :stop], &handle_event/4, nil)
    Phoenix.PubSub.subscribe(NeonLambda.PubSub, "balancer")
    schedule_check()
    {:ok, %{enabled: true, buckets: %{}, wait_for_updated: false, workers: 1}}
  end

  @impl true
  def terminate(_, _) do
    :telemetry.detach("neon-scaler")
  end

  @impl true
  def handle_call(:status, _, %{enabled: enabled} = state) do
    {:reply, %{enabled: enabled}, state}
  end

  def handle_call({:set, v}, _, state) do
    {:reply, :ok, %{state | enabled: v}}
  end

  @impl true
  def handle_cast(:event, %{buckets: buckets} = state) do
    current_time = System.system_time(:second)
    oldest_relevant_bucket = current_time - @seconds
    updated_buckets = Map.update(buckets, current_time, 0, &(&1 + 1))

    cleaned_buckets =
      Enum.reduce(updated_buckets, %{}, fn {bucket, count}, acc_buckets ->
        if bucket >= oldest_relevant_bucket do
          Map.put(acc_buckets, bucket, count)
        else
          acc_buckets
        end
      end)

    state = %{state | buckets: cleaned_buckets}

    {:noreply, maybe_scale(state)}
  end

  def handle_event(_, _, _, _) do
    GenServer.cast(__MODULE__, :event)
  end

  @impl true
  def handle_info(:updated, state) do
    workers = NeonLambda.Balancer.status() |> Enum.count()
    state = maybe_scale(%{state | workers: workers, wait_for_updated: false})
    {:noreply, state}
  end

  def handle_info(:maybe_scale, state) do
    state = maybe_scale(state)
    schedule_check()
    {:noreply, state}
  end

  defp maybe_scale(%{enabled: false} = state) do
    state
  end

  defp maybe_scale(%{wait_for_updated: true} = state) do
    state
  end

  defp maybe_scale(%{workers: workers, buckets: buckets} = state) do
    current_time = System.system_time(:second)
    oldest_relevant_bucket = current_time - @seconds

    count =
      Enum.reduce(buckets, 0, fn {bucket, count}, acc_count ->
        if bucket >= oldest_relevant_bucket do
          acc_count + count
        else
          acc_count
        end
      end)

    # terrible scaling logic ;) just for demo purposes
    if count > @req_threashold * workers do
      if workers < @max_replicas do
        NeonLambda.Balancer.scale_up()
        %{state | wait_for_updated: true}
      else
        state
      end
    else
      if workers > 1 && count < @req_threashold * (workers - 1) do
        NeonLambda.Balancer.scale_down()
        %{state | wait_for_updated: true}
      else
        state
      end
    end
  end

  defp schedule_check do
    Process.send_after(self(), :maybe_scale, 1000)
  end
end
