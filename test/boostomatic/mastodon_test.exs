defmodule Boostomatic.MastodonTest do
  use ExUnit.Case
  # use Boostomatic.DataCase
  use Oban.Testing, repo: Bonfire.Common.Repo
  use Bonfire.Common.Settings

  setup tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    :ok
  end

  doctest Boostomatic.Service.Mastodon
  doctest Boostomatic.Helpers.MastoAPI

  @moduledoc """
  Integration tests for the MastoAPI helper module
  """

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    user = Bonfire.Me.Fake.fake_user!()

    user =
      Bonfire.Common.Utils.current_user(
        Settings.put(
          Boostomatic.Service.Mastodon,
          [base_url: base_url, access_token: "test_token"],
          current_user: user
        )
      )

    {:ok, bypass: bypass, user: user}
  end

  test "worker handles rate limiting", %{bypass: bypass, user: user} do
    Bypass.expect(bypass, fn conn ->
      if "/api/v2/search" == conn.request_path do
        Plug.Conn.resp(conn, 429, "Too Many Requests")
      end
    end)

    activity = %{
      "id" => "http://localhost/123",
      "content" => "test post"
    }

    assert {:snooze, 60} =
             perform_job(Boostomatic.Worker, %{
               "activity" => activity,
               "user_id" => user.id,
               "service" => Boostomatic.Service.Mastodon
             })
  end

  test "prepare_client/2 creates a valid Req client", %{user: user} do
    {:ok, client} = Boostomatic.Service.Mastodon.prepare_client(user)

    assert %Req.Request{} = client
    assert client.headers["authorization"] == ["Bearer test_token"]
    assert client.headers["content-type"] == ["application/json"]
  end

  test "boost/2 handles successful response", %{bypass: bypass, user: user} do
    Bypass.expect(bypass, fn conn ->
      if "/api/v2/search" == conn.request_path do
        Plug.Conn.resp(conn, 200, ~s({"statuses": [{"id": "456"}]}))
      else
        assert "/api/v1/statuses/456/reblog" == conn.request_path
        Plug.Conn.resp(conn, 200, ~s({"id": "789"}))
      end
    end)

    {:ok, client} = Boostomatic.Service.Mastodon.prepare_client(user)

    assert {:ok, _} =
             Boostomatic.Service.Mastodon.boost(%{"id" => "http://localhost/123"}, client)
  end

  test "boost/2 handles rate limiting", %{bypass: bypass, user: user} do
    Bypass.expect(bypass, fn conn ->
      if "/api/v2/search" == conn.request_path do
        Plug.Conn.resp(conn, 429, "Too Many Requests")
      end
    end)

    # Bypass.expect_once(bypass, "POST", "/api/v1/statuses/123/reblog", fn conn ->
    #   Plug.Conn.resp(conn, 429, "Too Many Requests")
    # end)

    {:ok, client} = Boostomatic.Service.Mastodon.prepare_client(user)

    assert {:error, :rate_limited} =
             Boostomatic.Service.Mastodon.boost(%{"id" => "http://localhost/123"}, client)
  end
end

defmodule Boostomatic.PixelfedServiceTest do
  use ExUnit.Case
  # use Boostomatic.DataCase
  use Oban.Testing, repo: Bonfire.Common.Repo
  use Bonfire.Common.Settings

  setup tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    user = Bonfire.Me.Fake.fake_user!()

    user =
      Bonfire.Common.Utils.current_user(
        Settings.put(
          Boostomatic.Service.Pixelfed,
          [base_url: base_url, access_token: "test_token"],
          current_user: user
        )
      )

    {:ok, bypass: bypass, user: user}
  end

  doctest Boostomatic.Service.Pixelfed

  describe "validate_activity?/2" do
    test "validates activity with media attachments", %{user: user} do
      activity = %{
        "id" => "http://localhost/123",
        "inReplyTo" => nil,
        "object" => %{"image" => [%{type: "image"}]}
      }

      assert Boostomatic.Service.Pixelfed.validate_activity?(activity, user)
    end

    test "rejects activity without media", %{user: user} do
      activity = %{
        "id" => "http://localhost/123",
        "inReplyTo" => nil,
        "object" => %{"image" => []}
      }

      refute Boostomatic.Service.Pixelfed.validate_activity?(activity, user)
    end

    test "respects reply settings", %{user: user} do
      Settings.put(:pixelfed_boost_replies, false, current_user: user)

      activity = %{
        "id" => "http://localhost/123",
        "inReplyTo" => "456",
        "object" => %{"image" => [%{type: "image"}]}
      }

      refute Boostomatic.Service.Pixelfed.validate_activity?(activity, user)
    end
  end

  test "worker successfully boosts valid activity", %{user: user, bypass: bypass} do
    Bypass.expect(bypass, fn conn ->
      if "/api/v2/search" == conn.request_path do
        Plug.Conn.resp(conn, 200, ~s({"statuses": [{"id": "456"}]}))
      else
        assert "/api/v1/statuses/456/reblog" == conn.request_path
        Plug.Conn.resp(conn, 200, ~s({"id": "789"}))
      end
    end)

    activity = %{
      "id" => "http://localhost/123",
      "content" => "test post",
      "object" => %{"image" => [%{"type" => "image"}]}
    }

    assert {:ok, "789"} =
             perform_job(Boostomatic.Worker, %{
               "activity" => activity,
               "user_id" => user.id,
               "service" => Boostomatic.Service.Pixelfed
             })
  end

  test "worker cancels invalid activities", %{user: user} do
    activity = %{
      "id" => "http://localhost/123",
      "content" => "test post"
    }

    assert {:cancel, :invalid_activity} =
             perform_job(Boostomatic.Worker, %{
               "activity" => activity,
               "user_id" => user.id,
               "service" => Boostomatic.Service.Pixelfed
             })
  end
end
