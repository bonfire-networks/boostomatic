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

