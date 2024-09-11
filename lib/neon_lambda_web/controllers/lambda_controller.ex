defmodule NeonLambdaWeb.LambdaController do
  use NeonLambdaWeb, :controller

  require Logger

  def deploy(conn, _params) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    endpoint = NeonLambda.Balancer.deploy(body)
    json(conn, %{lambda_endpoint: endpoint})
  end
end
