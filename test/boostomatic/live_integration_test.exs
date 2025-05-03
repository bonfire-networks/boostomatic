defmodule Boostomatic.LiveIntegrationTest do
  use ExUnit.Case
  # use Boostomatic.ConnCase
  use Oban.Testing, repo: Bonfire.Common.Repo
  use Bonfire.Common.Settings

  @moduletag :live_federation

  setup_all tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    :ok
  end

  setup do
    user = Bonfire.Me.Fake.fake_user!()

    user =
      Bonfire.Common.Utils.current_user(
        Settings.put(
          [Boostomatic, :services_enabled],
          [
            Boostomatic.Service.Mastodon,
            Boostomatic.Service.Pixelfed,
            Boostomatic.Service.Bluesky
          ],
          current_user: user
        )
      )

    {:ok, user: user}
  end

  if [
       "PIXELFED_TEST_POST_ID",
       "MASTODON_ACCESS_TOKEN",
       "MASTODON_TEST_POST_ID"
     ]
     |> Enum.all?(&System.get_env/1) do
    test "successfully boosts a real post to Mastodon", %{user: user} do
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

  if [
       "MASTODON_TEST_POST_ID",
       "PIXELFED_BASE_URL",
       "PIXELFED_ACCESS_TOKEN",
       "PIXELFED_TEST_POST_ID"
     ]
     |> Enum.all?(&System.get_env/1) do
    test "successfully boosts a post with media to Pixelfed", %{user: user} do
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

  if [
       "MASTODON_TEST_POST_ID",
       "BLUESKY_USERNAME",
       "BLUESKY_PASSWORD"
       # "BLUESKY_PDS_URL",
       # "BLUESKY_TEST_POST_URI",
     ]
     |> Enum.all?(&System.get_env/1) do
    test "successfully posts to Bluesky", %{user: user} do
      user =
        Bonfire.Common.Utils.current_user(
          Settings.put(
            Boostomatic.Service.Bluesky,
            [
              username: System.fetch_env!("BLUESKY_USERNAME"),
              password: System.fetch_env!("BLUESKY_PASSWORD"),
              pds: System.get_env("BLUESKY_PDS_URL")
            ],
            current_user: user
          )
        )

      test_post_id = System.fetch_env!("MASTODON_TEST_POST_ID")

      # Create activity from Mastodon post
      activity = %{
        "id" => test_post_id,
        "visibility" => "public",
        "content" => """
        Overheard, about the AI craze: 

        > Before, if you were known to take hallucinogens, you'd be fired on the spot.
        > Now workplaces are eager to replace much of their workforce with hallucinating agents.
        """,

        #  TODO: fetch content from ID instead?
        "source" => "Mastodon"
      }

      # Attempt to cross-post
      assert {:ok, job} = Boostomatic.boost_activity(activity, user, Boostomatic.Service.Bluesky)

      # Process the job immediately in test
      assert {:ok, post_uri} = perform_job(Boostomatic.Worker, job.args)

      assert is_binary(post_uri)
      assert post_uri =~ "at://"

      # TODO: Verify the post exists on Bluesky
      # {:ok, session} = Boostomatic.Service.Bluesky.prepare_client(user)

      # # Get the post details
      # {:ok, post} = BlueskyEx.Client.RecordManager.get_post(session, post_uri)

      # assert post.body["uri"] == post_uri
      # assert post.body["value"]["text"] =~ "Test post content"
      # assert post.body["value"]["text"] =~ test_post_id
    end
  end
end
