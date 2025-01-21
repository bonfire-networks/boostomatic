defmodule Boostomatic.Helpers.MastoAPI do
  import Untangle

  @moduledoc """
  Helper module for services implementing the Mastodon-compatible API.
  """
  alias Bonfire.Common.Settings

  def prepare_client(user, service_name) do
    settings = Settings.get(service_name, [], current_user: user)
    base_url = settings[:base_url]
    token = settings[:access_token]

    if is_nil(base_url) or is_nil(token) do
      error(settings, "missing_credentials")
      debug(settings, user)
      {:error, :missing_credentials}
    else
      {:ok, build_client(base_url, token)}
    end
  end

  @doc """
  Resolves a status URI to a local ID on the target instance and performs the boost.

  ## Examples

      > client = Req.new(base_url: "https://mastodon.social")
      > activity = %{"id" => "https://otherinstance.social/users/someone/statuses/123456"}
      > Boostomatic.MastoAPI.boost(activity, client)
      {:ok, "789"}

  """
  def boost(activity, client) do
    with {:ok, status_id} <- resolve_status_id(activity["id"], client),
         {:ok, boost_id} <- perform_boost(status_id, client) do
      {:ok, boost_id}
    end
  end

  @doc """
  Resolves a remote status URI to a local status ID using the search API.

  ## Examples

      > client = Req.new(base_url: "https://mastodon.social")
      > uri = "https://otherinstance.social/users/someone/statuses/123456"
      > resolve_status_id(uri, client)
      {:ok, "456789"}

  """
  def resolve_status_id(uri, client) do
    search_url = "/api/v2/search"
    query = [q: uri, type: "statuses", resolve: true]

    case Req.get(client, url: search_url, params: query) do
      {:ok, %{status: 200, body: body}} ->
        do_resolve_status_id(body, uri)

      {:ok, %{status: status}} when status in [429, 503] ->
        {:error, :rate_limited}

      {:error, _} = error ->
        error
    end
  end

  defp do_resolve_status_id(body, uri) do
    case body do
      body when is_binary(body) ->
        do_resolve_status_id(Jason.decode!(body), uri)

      %{"statuses" => [%{"id" => id} | _]} ->
        # TODO: check that it matches the uri
        debug(body, "body for #{uri}")
        {:ok, id}

      %{"statuses" => []} ->
        error(body, "status #{uri} not_found")
        {:error, :status_not_found}

      e ->
        error(e, "Invalid response")
        {:error, :invalid_response}
    end
  end

  @doc """
  Performs the actual boost operation using the local status ID.

  ## Examples

      > client = Req.new(base_url: "https://mastodon.social")
      > Boostomatic.MastoAPI.perform_boost("123456", client)
      {:ok, "789012"}

  """
  def perform_boost(status_id, client) do
    url = "/api/v1/statuses/#{status_id}/reblog"

    case Req.post(client, url: url) do
      {:ok, %{status: 200, body: %{"id" => id}}} ->
        {:ok, id}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        with {:ok, %{"id" => id} = _data} <- Jason.decode(body) do
          {:ok, id}
        else
          {:ok, data} ->
            {:ok, data}

          _ ->
            {:ok, body}
        end

      {:ok, %{status: status}, headers: headers} when status in [302] ->
        error(headers, "redirecting, are we not authed?")
        {:error, :redirecting}

      {:ok, %{status: status}} when status in [429, 503] ->
        {:error, :rate_limited}

      {:error, _} = error ->
        error
    end
  end

  defp build_client(base_url, token) do
    Req.new(
      base_url: base_url,
      redirect: false,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ]
    )
  end

  def is_boost?(activity), do: activity["type"] == "Boost"

  def is_reply?(activity),
    do: not is_nil(activity["inReplyTo"] || activity["object"]["inReplyTo"])
end
