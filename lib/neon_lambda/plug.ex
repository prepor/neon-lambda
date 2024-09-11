defmodule NeonLambda.Plug do
  use Plug.Builder
  # import Plug.Conn
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart]

  plug :handle

  def handle(conn, _opts) do
    conn = conn |> fetch_query_params()

    [_, id, path] = String.split(conn.request_path, "/", parts: 3)

    req = %{
      method: conn.method,
      path: "/" <> path,
      body: conn.body_params,
      query: conn.query_params
    }

    res =
      NeonLambda.Balancer.handle(id, req)

    Enum.reduce(res["headers"] || [], conn, fn {k, v}, conn ->
      put_resp_header(conn, k, v)
    end)
    |> send_resp(res["status"], res["body"] || "")
  end
end
