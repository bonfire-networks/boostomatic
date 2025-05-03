defmodule Boostomatic do
  @moduledoc """
  Boostomatic is a service for automatically boosting posts across different social platforms.
  """
  use Bonfire.Common.Settings

  # TODO - Boost to default service 
  def boost_activity(activity, user) do
    boost_activity(activity, user, get_service(user))
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
      boost_activity(activity, user, service)
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
