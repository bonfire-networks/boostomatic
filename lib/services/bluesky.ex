defmodule Boostomatic.Service.Bluesky do
  @moduledoc """
  Bluesky service integration for Boostomatic.
  Creates new posts with links to original content instead of boosts.
  """
  @behaviour Boostomatic.Service.Behaviour

  import Untangle
  use Bonfire.Common.Settings

  @doc """
  Prepares a Bluesky client with the given credentials.
  Expects config map with :username, :password, and optional :pds (default: bsky.social)
  """
  @impl true
  def prepare_client(user) do
    settings = Settings.get(__MODULE__, [], current_user: user)

    creds = %BlueskyEx.Client.Credentials{
      username: settings[:username] || raise("Missing Bluesky username"),
      password: settings[:password] || raise("Missing Bluesky password")
    }

    pds = Map.get(settings, :pds) || "https://bsky.social"

    case BlueskyEx.Client.Session.create(creds, pds) do
      %BlueskyEx.Client.Session{} = session -> {:ok, session}
      e -> error(e, "Failed to authenticate with Bluesky")
    end
  rescue
    e in MatchError ->
      error(e, "Failed to authenticate with Bluesky")
  end

  @doc """
  Validates if the activity should be cross-posted.
  Can be customized based on content type, visibility, etc.
  """
  @impl true
  def validate_activity?(activity, _user) do
    # Add custom validation logic here
    # Example: Only cross-post public posts with text content
    case activity do
      %{"content" => content} when is_binary(content) -> true
      _ -> false
    end
  end

  @doc """
  Creates a new post on Bluesky with a link to the original content.
  Returns {:ok, post_id} on success, {:error, reason} on failure.
  """
  @impl true
  def boost(activity, client) do
    # Format the cross-post text
    text = format_cross_post_text(activity)

    case BlueskyEx.Client.RecordManager.create_post(client, text: text)
         |> debug("maybe_created") do
      %{status_code: 200, body: response} when is_binary(response) ->
        with {:ok, response} <- Jason.decode(response) do
          {:ok, response["uri"] || response["id"]}
        else
          e -> {:ok, response}
        end

      %{status_code: 200, body: response} ->
        {:ok, response}

      %{status_code: status} when status in [429, 503] ->
        {:error, :rate_limited}

      e ->
        error(e, "Failed to create Bluesky post")
    end
  end

  # Private helper functions

  defp format_cross_post_text(activity) do
    original_url = activity["id"]

    footer = "🔄 Reply on the fediverse at #{original_url}"
    # 🔄 Cross-posted, visit the original post to participate in the discussion: #{original_url}

    # Respect Bluesky's character limit of 300 
    content = String.slice(activity["content"], 0, 300 - String.length(footer) - 2)

    """
    #{content}

    #{footer}
    """
  end
end
