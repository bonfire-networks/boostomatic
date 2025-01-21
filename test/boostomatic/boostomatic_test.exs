defmodule BoostomaticTest do
  use ExUnit.Case
  # use Boostomatic.DataCase
  use Oban.Testing, repo: Bonfire.Common.Repo
  alias Bonfire.Common.Settings

  setup tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    # Ensure Oban job queue is empty before each test
    Oban.drain_queue(queue: :boost_activities)

    user = Bonfire.Me.Fake.fake_user!()

    # Setup test settings
    user =
      Bonfire.Common.Utils.current_user(
        Settings.put(
          [Boostomatic, :services_enabled],
          [Boostomatic.Service.Mastodon, Boostomatic.Service.Pixelfed],
          current_user: user
        )
      )

    {:ok, user: user}
  end

  doctest Boostomatic

  test "boost_activity creates an Oban job", %{user: user} do
    activity = %{"id" => "http://localhost/123", content: "test post"}

    assert {:ok, %Oban.Job{}} = Boostomatic.boost_activity(activity, user)

    assert_enqueued(
      worker: Boostomatic.Worker,
      args: %{
        activity: activity,
        user_id: user.id,
        service: Boostomatic.Service.Mastodon
      }
    )
  end

  test "boost_activity_to_all creates jobs for enabled services", %{user: user} do
    activity = %{"id" => "http://localhost/123", content: "test post"}

    results = Boostomatic.boost_activity_to_all(activity, user)
    assert length(results) == 2

    assert_enqueued(
      worker: Boostomatic.Worker,
      args: %{
        activity: activity,
        user_id: user.id,
        service: Boostomatic.Service.Mastodon
      }
    )

    assert_enqueued(
      worker: Boostomatic.Worker,
      args: %{
        activity: activity,
        user_id: user.id,
        service: Boostomatic.Service.Pixelfed
      }
    )
  end
end
