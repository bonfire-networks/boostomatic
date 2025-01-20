defmodule Boostomatic.LiveIntegrationTest do
  use ExUnit.Case
  # use Boostomatic.ConnCase
  use Oban.Testing, repo: Bonfire.Common.Repo
  alias Bonfire.Common.Settings

  @moduletag :live_federation

  setup_all tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    unless all_env_vars_present?() do
      raise """
      Missing required environment variables for live integration tests.
      Required vars:
        MASTODON_BASE_URL
        MASTODON_ACCESS_TOKEN
        MASTODON_TEST_POST_ID
        PIXELFED_BASE_URL
        PIXELFED_ACCESS_TOKEN
        PIXELFED_TEST_POST_ID
      """
    end

    :ok
  end

  setup do
    user = Bonfire.Me.Fake.fake_user!()

    user =
      Bonfire.Common.Utils.current_user(
        Settings.put(
          Boostomatic.Service.Mastodon,
          [
            base_url: System.fetch_env!("MASTODON_BASE_URL"),
            access_token: System.fetch_env!("MASTODON_ACCESS_TOKEN")
          ],
          current_user: user
        )
      )

    user =
      Bonfire.Common.Utils.current_user(
        Settings.put(
          Boostomatic.Service.Pixelfed,
          [
            base_url: System.fetch_env!("PIXELFED_BASE_URL"),
            access_token: System.fetch_env!("PIXELFED_ACCESS_TOKEN")
          ],
          current_user: user
        )
      )

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

  describe "Mastodon to Pixelfed" do
    test "successfully boosts a real post", %{user: user} do
      test_post_id = System.fetch_env!("MASTODON_TEST_POST_ID")

      activity = %{
        "id" => test_post_id,
        "inReplyTo" => nil,
        "object" => %{"image" => [%{"type" => "image"}]}
      }

      assert {:ok, job} = Boostomatic.boost_activity(activity, user, Boostomatic.Service.Pixelfed)

      # Process the job immediately in test
      assert {:ok, boosted_id} = perform_job(Boostomatic.Worker, job.args)

      assert is_binary(boosted_id)

      # Verify the boost exists by checking the status
      {:ok, client} = Boostomatic.Service.Mastodon.prepare_client(user)

      {:ok, response} =
        Req.get(client,
          url: "/api/v1/statuses/#{boosted_id}"
        )

      assert response.status == 200
      assert test_post_id =~ response.body["reblog"]["id"]

      # Second boost should fail?
      {:ok, job} = Boostomatic.boost_activity(activity, user, Boostomatic.Service.Pixelfed)
      result = perform_job(Boostomatic.Worker, job.args)

      assert {:error, _} = result
    end
  end

  describe "Pixelfed to Mastodon" do
    test "successfully boosts a post with media", %{user: user} do
      test_post_id = System.fetch_env!("PIXELFED_TEST_POST_ID")

      activity = %{
        "id" => test_post_id,
        "inReplyTo" => nil
      }

      assert {:ok, job} = Boostomatic.boost_activity(activity, user, Boostomatic.Service.Mastodon)

      assert {:ok, boosted_id} = perform_job(Boostomatic.Worker, job.args)

      assert is_binary(boosted_id)

      # Verify the boost
      {:ok, client} = Boostomatic.Service.Pixelfed.prepare_client(user)

      {:ok, response} =
        Req.get(client,
          url: "/api/v1/statuses/#{boosted_id}"
        )

      assert response.status == 200
      assert response.body["reblog"]["id"] == test_post_id

      # Second boost should fail?
      {:ok, job} = Boostomatic.boost_activity(activity, user, Boostomatic.Service.Mastodon)
      result = perform_job(Boostomatic.Worker, job.args)

      assert {:error, _} = result
    end
  end

  # Helper functions

  defp all_env_vars_present? do
    [
      "MASTODON_BASE_URL",
      "MASTODON_ACCESS_TOKEN",
      "MASTODON_TEST_POST_ID",
      "PIXELFED_BASE_URL",
      "PIXELFED_ACCESS_TOKEN",
      "PIXELFED_TEST_POST_ID"
    ]
    |> Enum.all?(&System.get_env/1)
  end
end
