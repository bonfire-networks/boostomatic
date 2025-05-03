defmodule Boostomatic.BlueskyServiceTest do
  use ExUnit.Case
  use Oban.Testing, repo: Bonfire.Common.Repo
  use Bonfire.Common.Settings

  setup tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    bypass = Bypass.open()
    pds = "http://localhost:#{bypass.port}"

    user = Bonfire.Me.Fake.fake_user!()

    user =
      Bonfire.Common.Utils.current_user(
        Settings.put(
          Boostomatic.Service.Bluesky,
          [
            username: "test.user",
            password: "test_password",
            pds: pds
          ],
          current_user: user
        )
      )

    {:ok, bypass: bypass, user: user}
  end

  doctest Boostomatic.Service.Bluesky

  describe "prepare_client/2" do
    test "creates valid Bluesky session", %{bypass: bypass, user: user} do
      Bypass.expect(bypass, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/xrpc/com.atproto.server.createSession"

        Plug.Conn.resp(
          conn,
          200,
          ~s({"accessJwt": "test_jwt", "did": "did:test:123", "refreshJwt": "123"})
        )
      end)

      {:ok, client} = Boostomatic.Service.Bluesky.prepare_client(user)
      assert %BlueskyEx.Client.Session{} = client
      assert client.did == "did:test:123"
    end

    test "handles authentication failure", %{bypass: bypass, user: user} do
      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 401, ~s({"error": "Invalid credentials"}))
      end)

      assert {:error, _} = Boostomatic.Service.Bluesky.prepare_client(user)
    end
  end

  describe "validate_activity?/2" do
    test "validates public posts with content", %{user: user} do
      activity = %{
        "visibility" => "public",
        "content" => "Test post content",
        "id" => "https://example.com/post/123"
      }

      assert Boostomatic.Service.Bluesky.validate_activity?(activity, user)
    end

    # TODO?
    # test "rejects private posts", %{user: user} do
    #   activity = %{
    #     "visibility" => "private",
    #     "content" => "Test post content",
    #     "url" => "https://example.com/post/123"
    #   }

    #   refute Boostomatic.Service.Bluesky.validate_activity?(activity, user)
    # end
  end

  describe "boost/2" do
    test "successfully creates cross-post, respecting character limits", %{
      bypass: bypass,
      user: user
    } do
      id = "https://example.com/post/123"

      content =
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Praesent tempus vehicula scelerisque. Cras nec feugiat nulla. Nullam hendrerit laoreet massa, non fermentum nisi finibus eget. Morbi dictum consectetur magna. Etiam pretium pretium vulputate. Sed magna eros, faucibus ac suscipit sed efficitur."

      Bypass.expect(bypass, fn conn ->
        case conn.request_path do
          "/xrpc/com.atproto.server.createSession" ->
            Plug.Conn.resp(
              conn,
              200,
              ~s({"accessJwt": "test_jwt", "did": "did:test:123", "refreshJwt": "123"})
            )

          "/xrpc/com.atproto.repo.createRecord" ->
            assert {:ok, body, _conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)

            assert decoded["record"]["text"] =~
                     "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Praesent tempus vehicula scelerisque. Cras nec feugiat nulla. Nullam hendrerit laoreet massa, non fermentum nisi finibus eget. Morbi dictum consectetur magna. Etiam pretium pretium vulp\n\n🔄 Reply on the fediverse at https://example.com/post/123"

            Plug.Conn.resp(conn, 200, ~s({"uri": "at://did:test:123/app.bsky.feed.post/1"}))
        end
      end)

      {:ok, client} = Boostomatic.Service.Bluesky.prepare_client(user)

      activity = %{
        "visibility" => "public",
        "content" => content,
        "id" => id,
        "source" => "Mastodon"
      }

      assert {:ok, post_uri} = Boostomatic.Service.Bluesky.boost(activity, client)
      assert post_uri =~ "at://did:test:123"
    end

    test "handles rate limiting", %{bypass: bypass, user: user} do
      Bypass.expect(bypass, fn conn ->
        case conn.request_path do
          "/xrpc/com.atproto.server.createSession" ->
            Plug.Conn.resp(
              conn,
              200,
              ~s({"accessJwt": "test_jwt", "did": "did:test:123", "refreshJwt": "123"})
            )

          "/xrpc/com.atproto.repo.createRecord" ->
            Plug.Conn.resp(conn, 429, "Too Many Requests")
        end
      end)

      {:ok, client} = Boostomatic.Service.Bluesky.prepare_client(user)

      activity = %{
        "visibility" => "public",
        "content" => "Test post content",
        "id" => "https://example.com/post/123",
        "source" => "Mastodon"
      }

      assert {:error, :rate_limited} = Boostomatic.Service.Bluesky.boost(activity, client)
    end
  end

  describe "worker integration" do
    test "worker successfully cross-posts valid activity", %{bypass: bypass, user: user} do
      Bypass.expect(bypass, fn conn ->
        case conn.request_path do
          "/xrpc/com.atproto.server.createSession" ->
            Plug.Conn.resp(
              conn,
              200,
              ~s({"accessJwt": "test_jwt", "did": "did:test:123", "refreshJwt": "123"})
            )

          "/xrpc/com.atproto.repo.createRecord" ->
            Plug.Conn.resp(conn, 200, ~s({"uri": "at://did:test:123/app.bsky.feed.post/1"}))
        end
      end)

      activity = %{
        "visibility" => "public",
        "content" => "Test post content",
        "id" => "https://example.com/post/123",
        "source" => "Mastodon"
      }

      assert {:ok, post_uri} =
               perform_job(Boostomatic.Worker, %{
                 "activity" => activity,
                 "user_id" => user.id,
                 "service" => Boostomatic.Service.Bluesky
               })

      assert post_uri =~ "at://did:test:123"
    end

    test "worker handles invalid activities", %{user: user} do
      activity = %{
        "id" => "https://example.com/post/123",
        "content" => nil
      }

      assert {:cancel, :invalid_activity} =
               perform_job(Boostomatic.Worker, %{
                 "activity" => activity,
                 "user_id" => user.id,
                 "service" => Boostomatic.Service.Bluesky
               })
    end
  end
end
