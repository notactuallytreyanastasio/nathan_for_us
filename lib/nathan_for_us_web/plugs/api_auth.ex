defmodule NathanForUsWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates JSON ingest requests via the "x-api-key" header.

  Two kinds of keys are accepted:

  - A user's personal API key (`users.api_key`, the `fc_...` value shown on
    /setup). On success the matching user is assigned as `conn.assigns.api_user`.
  - The legacy shared key from `config :nathan_for_us, :ingest_api_key`
    (INGEST_API_KEY in `config/runtime.exs`), kept for existing deployments.

  Personal keys always work, even with no shared key configured. Shared-key
  comparison is constant-time to avoid timing attacks.
  """

  @behaviour Plug

  import Plug.Conn

  alias NathanForUs.Accounts

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    provided_key =
      conn
      |> get_req_header("x-api-key")
      |> List.first()
      |> to_string()

    cond do
      provided_key == "" ->
        deny(conn, 401, "missing api key")

      user = Accounts.get_user_by_api_key(provided_key) ->
        assign(conn, :api_user, user)

      shared_key_match?(provided_key) ->
        conn

      true ->
        deny(conn, 401, "invalid api key")
    end
  end

  defp shared_key_match?(provided_key) do
    case Application.get_env(:nathan_for_us, :ingest_api_key) do
      key when key in [nil, ""] -> false
      expected_key -> Plug.Crypto.secure_compare(provided_key, expected_key)
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
