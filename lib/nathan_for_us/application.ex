defmodule NathanForUs.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    base_children = [
      NathanForUs.Repo,
      # Background work that touches the Repo (cache warming) runs under this
      # supervisor. It starts after the Repo, so on shutdown its tasks are
      # torn down before the Repo they query.
      {Task.Supervisor, name: NathanForUs.TaskSupervisor},
      {DNSCluster, query: Application.get_env(:nathan_for_us, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: NathanForUs.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: NathanForUs.Finch},
      # Start cache processes for memory-efficient GIF and frame storage
      NathanForUs.GifCache,
      NathanForUs.FrameCache,
      NathanForUs.CacheManager,
      # Telemetry's poller measures the caches, so it starts after them
      NathanForUsWeb.Telemetry
    ]

    # Conditionally add services based on environment
    optional_children = []

    optional_children =
      if Application.get_env(:nathan_for_us, :start_video_processing, true) do
        [NathanForUs.VideoProcessing | optional_children]
      else
        optional_children
      end

    children = base_children ++ optional_children ++ [NathanForUsWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NathanForUs.Supervisor]
    Supervisor.start_link(children ++ factory_report(), opts)
  end

  # The report the factory (obs_factor) reads: the BEAM, every connected
  # LiveView, per-table repo time, and counted streams, on an internal port
  # (9568, the library default). On in production only (config/prod.exs), so
  # dev and test never bind the port.
  #
  # observer: true serves /observer reads without a report token, as in
  # marginalia: the port is not published or proxied, only the compose
  # network reaches it. Observer actions (kill, gc, restart) stay off unless
  # FACTORY_REPORT_ACTIONS_TOKEN is set in the container's environment; the
  # library reads that variable itself.
  defp factory_report do
    if Application.get_env(:nathan_for_us, :factory_report, false) do
      [{FactoryReport, app: :nathan_for_us, repos: [NathanForUs.Repo], observer: true}]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NathanForUsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
