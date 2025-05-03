defmodule Boostomatic.Service.Pixelfed do
  @moduledoc """
  Pixelfed implementation of the Boostomatic service behaviour.
  Validates that posts contain media attachments before boosting.

  # Config example for a user
  Settings.put([Boostomatic.Service.Pixelfed, [enabled, true, base_url: "https://pixelfed.social", access_token: "your_token", boost_replies: false], current_user: user)
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

    cond do
      not boost_replies? && Boostomatic.Helpers.MastoAPI.is_reply?(activity) -> false
      not has_media?(activity) -> false
      true -> true
    end
  end

  @impl true
  def boost(activity, client) do
    Boostomatic.Helpers.MastoAPI.boost(activity, client)
  end

  defp has_media?(activity) do
    List.wrap(activity["object"]["image"])
    |> length() > 0
  end
end
