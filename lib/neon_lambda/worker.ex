defmodule NeonLambda.Worker do
  require Logger

  use Supervisor

  defmodule Dispatcher do
    use GenServer

    def start_link(options) do
      GenServer.start_link(__MODULE__, options)
    end

    def handle(worker, request) do
      {:ok, GenServer.call(worker, {:request, request})}
    end

    @impl true
    def init(options) do
      {:ok, %{:conn => options[:conn], ctl_port: options[:ctl_port], ref: options[:ref]},
       {:continue, []}}
    end

    @impl true
    def handle_continue(_, state) do
      wait_for_compute(state[:ctl_port])
      NeonLambda.Balancer.worker_ready(state[:ref], self())
      {:noreply, state}
    end

    @impl true
    def handle_call({:deploy, id, lambda}, _from, %{:conn => conn} = state) do
      Logger.info(msg: "Deploy lambda", lambda: lambda)

      q = """
      CREATE OR REPLACE FUNCTION http_handle_#{id}(req json) RETURNS json AS $$ 
      #{lambda} 
      $$ LANGUAGE plv8 STRICT
      """

      Postgrex.query!(
        conn,
        q,
        []
      )

      {:reply, :ok, state}
    end

    @impl true
    def handle_call({:request, id, req}, _from, %{:conn => conn} = state) do
      Logger.info(msg: "Handling request", req: req)

      case Postgrex.query(conn, "select http_handle_#{id}($1::json)", [req]) do
        {:ok, %{:rows => [[res]]}} ->
          {:reply, {:ok, res}, state}

        {:error, %Postgrex.Error{postgres: %{code: :read_only_sql_transaction}}} ->
          {:reply, {:error, :write_in_replica}, state}
      end
    end

    defp wait_for_compute(port) do
      case compute_status(port) do
        :ready ->
          :ok

        :pending ->
          :timer.sleep(200)
          wait_for_compute(port)
      end
    end

    defp compute_status(port) do
      endpoint = "http://localhost:#{port}/status"
      Logger.info("Checking compute status #{endpoint}")

      case Req.get(endpoint, retry: false) do
        {:ok, %{body: body}} ->
          case Jason.decode!(body)["status"] do
            "running" ->
              :ready

            status ->
              Logger.info("Compute is not ready: #{status}")

              :pending
          end

        _ ->
          :pending
      end
    end
  end

  @type options :: [
          {:tenant_id, String.t()}
          | {:timeline_id, String.t()}
          | {:ctl_bin, String.t()}
          | {:pg_bin, String.t()}
          | {:type, :primary | :replica}
          | {:pg_port, integer()}
          | {:http_port, integer()}
          | {:balancer_ref, reference()}
        ]

  def start_link(options) do
    Supervisor.start_link(__MODULE__, options)
  end

  @impl true
  def init(options) do
    data = Briefly.create!(type: :directory)
    Logger.info(msg: "Start worker", data_dir: data)
    spec_path = generate_spec_json(data, options)
    {compute_spec, compute_conn_params} = compute_spec(data, spec_path, options)
    {:ok, conn} = Postgrex.start_link(compute_conn_params)

    Supervisor.init(
      [
        %{compute_spec | restart: :permanent},
        {Dispatcher, conn: conn, ctl_port: options[:http_port], ref: options[:balancer_ref]}
      ],
      strategy: :rest_for_one
    )
  end

  defp generate_spec_json(data_path, options) do
    spec_path = Path.join(data_path, "spec.json")

    pg_conf =
      case options[:type] do
        :primary ->
          """
          max_wal_senders=10
          wal_log_hints=off
          max_replication_slots=10
          hot_standby=on
          shared_buffers=1MB
          fsync=off
          max_connections=100
          wal_level=logical
          wal_sender_timeout=5s
          listen_addresses='127.0.0.1'
          port=#{options[:pg_port]}
          wal_keep_size=0
          restart_after_crash=off

          shared_preload_libraries=neon
          max_replication_write_lag=15MB
          max_replication_flush_lag=10GB
          synchronous_standby_names=walproposer
          neon.safekeepers='localhost:5454'
          """

        :replica ->
          """
          max_wal_senders=10
          wal_log_hints=off
          max_replication_slots=10
          hot_standby=on
          shared_buffers=1MB
          fsync=off
          max_connections=100
          wal_level=logical
          wal_sender_timeout=5s
          listen_addresses='127.0.0.1'
          port=#{options[:pg_port]}
          wal_keep_size=0
          restart_after_crash=off
          shared_preload_libraries=neon
          primary_conninfo='host=localhost port=5454 options=''-c timeline_id=#{options[:timeline_id]} tenant_id=#{options[:tenant_id]}'' application_name=replica replication=true'
          primary_slot_name='repl_#{options[:pg_port]}'
          hot_standby=on
          recovery_prefetch=off
          """
      end

    spec = %{
      format_version: 1.0,
      cluster: %{
        postgresql_conf: pg_conf,
        roles: [],
        databases: []
      },
      skip_pg_catalog_updates: true,
      tenant_id: options[:tenant_id],
      timeline_id: options[:timeline_id],
      pageserver_connstring: "postgresql://no_user@localhost:64000",
      safekeeper_connstrings: [
        "127.0.0.1:5454"
      ],
      mode:
        case options[:type] do
          :primary -> "Primary"
          :replica -> "Replica"
        end,
      shard_stripe_size: 32768
    }

    File.write!(spec_path, Jason.encode!(spec))
    spec_path
  end

  defp compute_spec(data_path, spec_path, options) do
    pgdata = Path.join(data_path, "pgdata")
    File.mkdir!(pgdata)
    connstr = "postgresql://cloud_admin@127.0.0.1:#{options[:pg_port]}/postgres"

    cmd =
      [
        options[:ctl_bin],
        "--pgdata",
        pgdata,
        "--connstr",
        connstr,
        "--spec-path",
        spec_path,
        "--http-port",
        options[:http_port] |> Integer.to_string(),
        "--pgbin",
        options[:pg_bin]
      ]

    {
      Task.child_spec(fn ->
        Logger.info(msg: "Starting compute", cmd: cmd)

        Exile.stream!(
          cmd,
          stderr: :redirect_to_stdout
        )
        |> Stream.map(&IO.write/1)
        |> Stream.run()
      end),
      [
        hostname: "127.0.0.1",
        port: options[:pg_port],
        username: "cloud_admin",
        database: "postgres",
        pool_size: 5
      ]
    }
  end
end
