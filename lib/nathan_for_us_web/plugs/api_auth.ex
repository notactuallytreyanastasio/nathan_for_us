defmodule NathanForUsWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates JSON ingest requests with a shared API key.

  The expected key is read from `config :nathan_for_us, :ingest_api_key`
  (set via the INGEST_API_KEY environment variable in `config/runtime.exs`).

  - When no key is configured, ingest is disabled and requests get a 503.
  - Otherwise the "x-api-key" request header must match the configured key.
    The comparison is constant-time to avoid timing attacks.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Application.get_env(:nathan_for_us, :ingest_api_key) do
      key when key in [nil, ""] ->
        deny(conn, 503, "ingest disabled")

      expected_key ->
        provided_key =
          conn
          |> get_req_header("x-api-key")
          |> List.first()
          |> to_string()

        if Plug.Crypto.secure_compare(provided_key, expected_key) do
          conn
        else
          deny(conn, 401, "invalid api key")
        end
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
