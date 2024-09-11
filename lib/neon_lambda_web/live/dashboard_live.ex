defmodule NeonLambdaWeb.DashboardLive do
  # In Phoenix v1.6+ apps, the line is typically: use MyAppWeb, :live_view
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(NeonLambda.PubSub, "balancer")

    {:ok,
     assign(socket,
       workers: NeonLambda.Balancer.status(),
       autoscaler: NeonLambda.Scaler.status().enabled
     )}
  end

  @impl true
  def handle_event("scale_up", _params, socket) do
    NeonLambda.Balancer.scale_up()
    {:noreply, socket}
  end

  def handle_event("scale_down", _params, socket) do
    NeonLambda.Balancer.scale_down()
    {:noreply, socket}
  end

  def handle_event("autoscaler-toggle", _params, socket) do
    NeonLambda.Scaler.set(!socket.assigns.autoscaler)
    {:noreply, assign(socket, autoscaler: !socket.assigns.autoscaler)}
  end

  @impl true
  def handle_info(:updated, socket) do
    {:noreply, assign(socket, :workers, NeonLambda.Balancer.status())}
  end
end
