defmodule Boostomatic.Service.Mastodon do
  @moduledoc """
  Mastodon implementation of the Boostomatic service behaviour.

  # Config example for a user
  Settings.put([Boostomatic.Service.Mastodon, [enabled, true, base_url: "https://mastodon.social", access_token: "your_token", boost_replies: false, boost_boosts: false], current_user: user)
  """

  @behaviour Boostomatic.Service.Behaviour
  use Bonfire.Common.Settings

  @impl true
  def prepare_client(user) do
    Boostomatic.Helpers.MastoAPI.prepare_client(user, __MODULE__)
  end

  @impl true
  def validate_activity?(activity, user) do
    boost_replies? = Settings.get([__MODULE__, :boost_replies], false, current_user: user)
    boost_boosts? = Settings.get([__MODULE__, :boost_boosts], false, current_user: user)

    cond do
      not boost_replies? && Boostomatic.Helpers.MastoAPI.is_reply?(activity) -> false
      not boost_boosts? && Boostomatic.Helpers.MastoAPI.is_boost?(activity) -> false
      true -> true
    end
  end

  @impl true
  def boost(activity, client) do
    Boostomatic.Helpers.MastoAPI.boost(activity, client)
  end
end
