defmodule Boostomatic do
  @moduledoc """
  Boostomatic is a service for automatically boosting posts across different social platforms.
  """
  alias Bonfire.Common.Settings

  # TODO - Boost to default service 
  def boost_activity(activity, user) do
    boost_activity(activity, get_service(user), user)
  end

  def boost_activity(activity, user, service) do
    %{
      activity: activity,
      user_id: user.id,
      service: service
    }
    |> Boostomatic.Worker.new()
    |> Oban.insert()
  end

  # Boost to all enabled services
  def boost_activity_to_all(activity, user) do
    enabled_services = get_enabled_services(user)

    Enum.map(enabled_services, fn service ->
      boost_activity(activity, service, user)
    end)
  end

  defp get_service(user) do
    # TODO default should be configurable by user
    get_enabled_services(user) |> List.first()
  end

  defp get_enabled_services(user) do
    Settings.get([Boostomatic, :services_enabled], [], current_user: user)
  end
end

defmodule Boostomatic.Worker do
  @moduledoc """
  Oban worker for processing boost requests.

  # Needs something like this in config:
  config :boostomatic, Oban,
    repo: YourApp.Repo,
    plugins: [Oban.Plugins.Pruner],
    queues: [boost_activities: 10]
  """

  use Oban.Worker,
    queue: :boost_activities,
    max_attempts: 3,
    unique: [period: 30]

  import Untangle

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"activity" => activity, "user_id" => user_id, "service" => service}
      }) do
    with %{} = user <- Bonfire.Common.Utils.maybe_apply(Bonfire.Me.Users, :get_current, user_id),
         service_module when not is_nil(service_module) <- get_service_module(service),
         {:ok, client} <- service_module.prepare_client(user),
         true <- service_module.validate_activity?(activity, user),
         {:ok, status_id} <- service_module.boost(activity, client) do
      info("Successfully boosted activity #{activity["id"]} for user #{user_id} to #{service}")
      {:ok, status_id}
    else
      nil ->
        error(service, "Invalid service")
        {:cancel, :invalid_service}

      false ->
        debug(activity, "Invalid activity")
        {:cancel, :invalid_activity}

      {:error, :rate_limited} ->
        {:snooze, 60}

      e ->
        error(e, "Failed to boost activity to #{service}")
    end
  end

  defp get_service_module("mastodon"), do: Boostomatic.Service.Mastodon
  defp get_service_module("pixelfed"), do: Boostomatic.Service.Pixelfed

  defp get_service_module(service) do
    Bonfire.Common.Types.maybe_to_module(service) || nil
  end
end

defmodule Boostomatic.Service.Behaviour do
  @moduledoc """
  Behaviour for implementing different social media service integrations.
  """

  # Setup client for new service
  @callback prepare_client(map()) :: {:ok, term()} | {:error, term()}

  # Check if activity is compatible and should be boosted
  @callback validate_activity?(map(), map()) :: boolean()

  # Boost logic
  @callback boost(map(), map()) :: {:ok, String.t()} | {:error, term()}
end

defmodule Boostomatic.Service.Mastodon do
  @moduledoc """
  Mastodon implementation of the Boostomatic service behaviour.

  # Config example for a user
  Settings.put([Boostomatic.Service.Mastodon, [enabled, true, base_url: "https://mastodon.social", access_token: "your_token", boost_replies: false, boost_boosts: false], current_user: user)
  """

  @behaviour Boostomatic.Service.Behaviour
  alias Bonfire.Common.Settings

  @impl true
  def prepare_client(user) do
    Boostomatic.Helpers.MastodonCompatible.prepare_client(user, __MODULE__)
  end

  @impl true
  def validate_activity?(activity, user) do
    boost_replies? = Settings.get([__MODULE__, :boost_replies], false, current_user: user)
    boost_boosts? = Settings.get([__MODULE__, :boost_boosts], false, current_user: user)

    cond do
      not boost_replies? && Boostomatic.Helpers.MastodonCompatible.is_reply?(activity) -> false
      not boost_boosts? && Boostomatic.Helpers.MastodonCompatible.is_boost?(activity) -> false
      true -> true
    end
  end

  @impl true
  def boost(activity, client) do
    Boostomatic.Helpers.MastodonCompatible.boost(activity, client)
  end
end

defmodule Boostomatic.Service.Pixelfed do
  @moduledoc """
  Pixelfed implementation of the Boostomatic service behaviour.
  Validates that posts contain media attachments before boosting.

  # Config example for a user
  Settings.put([Boostomatic.Service.Pixelfed, [enabled, true, base_url: "https://pixelfed.social", access_token: "your_token", boost_replies: false], current_user: user)
  """

  @behaviour Boostomatic.Service.Behaviour
  alias Bonfire.Common.Settings

  @impl true
  def prepare_client(user) do
    Boostomatic.Helpers.MastodonCompatible.prepare_client(user, __MODULE__)
  end

  @impl true
  def validate_activity?(activity, user) do
    boost_replies? = Settings.get([__MODULE__, :boost_replies], false, current_user: user)

    cond do
      not boost_replies? && Boostomatic.Helpers.MastodonCompatible.is_reply?(activity) -> false
      not has_media?(activity) -> false
      true -> true
    end
  end

  @impl true
  def boost(activity, client) do
    Boostomatic.Helpers.MastodonCompatible.boost(activity, client)
  end

  defp has_media?(activity) do
    List.wrap(activity["object"]["image"])
    |> length() > 0
  end
end

defmodule Boostomatic.Helpers.MastodonCompatible do
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
      > Boostomatic.MastodonCompatible.boost(activity, client)
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
      > Boostomatic.MastodonCompatible.perform_boost("123456", client)
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
