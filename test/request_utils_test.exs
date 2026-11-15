defmodule Hound.RequestUtilsTest do
  use ExUnit.Case, async: false

  alias Hound.FakeWebDriver
  alias Hound.RequestUtils
  alias Hound.WebDriverError

  @short_http [connect_timeout: 200, recv_timeout: 200, timeout: 200]

  @session_ok ~s({"sessionId": "sid-123", "status": 0})
  @no_such_element_legacy ~s({"value": {"message": "no such element: .foo"}})
  @no_such_element_w3c ~s({"value": {"error": "no such element", "message": "Unable to locate element"}})
  @unknown_json ~s(["totally", "unexpected"])
  @invalid_argument ~s({"value": {"message": "invalid argument"}})
  @value_ok ~s({"status": 0, "value": "ok"})
  @boom ~s({"value": {"message": "boom"}})

  setup do
    Application.put_env(:hound, :http, @short_http)
    Application.put_env(:hound, :retry_time, 0)
    :ok
  end

  defp with_fake_driver(responses, test_opts \\ []) do
    {:ok, server} =
      FakeWebDriver.start_link(
        responses: responses,
        fail_first: Keyword.get(test_opts, :fail_first, 0),
        refuse: Keyword.get(test_opts, :refuse, false)
      )

    restart_hound(server)
    on_exit(fn -> FakeWebDriver.stop(server) end)
    server
  end

  defp restart_hound(%{url: url}) do
    %URI{host: host, port: port} = URI.parse(url)

    # Re-point the existing named connection agent at the fake server.
    # Restarting the supervisor itself is not an option because the one
    # started by test_helper is linked to the VM's root process.
    state = Agent.get(Hound.ConnectionServer, & &1)

    on_exit(:restore_hound, fn ->
      if Process.whereis(Hound.ConnectionServer) do
        Agent.update(Hound.ConnectionServer, fn _ -> state end)
      end

      Application.delete_env(:hound, :http)
      Application.delete_env(:hound, :retry_time)
      Application.delete_env(:hound, :retries)
    end)

    Agent.update(Hound.ConnectionServer, fn s ->
      put_in(s.driver_info, %{
        s.driver_info
        | driver: "chrome_driver",
          host: "http://#{host}",
          port: port,
          path_prefix: ""
      })
    end)

    :ok
  end

  describe "session commands are never replayed" do
    test "create_session is submitted once even when retries are configured" do
      Application.put_env(:hound, :retries, 3)
      server = with_fake_driver(%{"session" => {200, @session_ok}})

      assert {:ok, "sid-123"} = Hound.Session.create_session("chrome", [])
      assert FakeWebDriver.request_count(server, "session") == 1
    end

    test "create_session is not retried on transport failure" do
      server = with_fake_driver(%{"session" => {200, @session_ok}}, refuse: true)

      assert {:error, %WebDriverError{transport: true}} =
               Hound.Session.create_session("chrome", [])

      # Nothing was ever accepted by the driver.
      assert FakeWebDriver.request_count(server, "session") == 0
    end

    test "destroy_session is submitted once on success" do
      server = with_fake_driver(%{:any => {204, ""}})

      assert :ok = Hound.Session.destroy_session("sid-123")
      assert FakeWebDriver.request_count(server, "session/sid-123") == 1
    end

    test "destroy_session is not retried on transport failure" do
      server = with_fake_driver(%{:any => {204, ""}}, refuse: true)

      assert {:error, %WebDriverError{transport: true}} =
               Hound.Session.destroy_session("sid-123")

      assert FakeWebDriver.request_count(server, "session/sid-123") == 0
    end
  end

  describe "state changing commands are not retried on driver errors" do
    test "a 4xx on a plain post is raised and submitted once" do
      server = with_fake_driver(%{:any => {400, @invalid_argument}})
      Application.put_env(:hound, :retries, 3)

      assert_raise WebDriverError, fn ->
        RequestUtils.make_req(:post, "session/sid/url", %{url: "http://x"})
      end

      assert FakeWebDriver.request_count(server, "session/sid/url") == 1
    end

    test "transport failure is replayed up to the retry budget, never silently swallowed" do
      server = with_fake_driver(%{:any => {200, @value_ok}}, refuse: true)
      Application.put_env(:hound, :retries, 2)

      assert {:error, %WebDriverError{transport: true}} =
               RequestUtils.make_req(:post, "session/sid/click", %{})

      assert FakeWebDriver.request_count(server, "session/sid/click") == 0
    end
  end

  describe "safe read commands" do
    test "categorized driver error is retried until retries are exhausted" do
      # The fake server keeps serving the same categorized error, so we
      # assert on the number of submitted requests instead of a success.
      server = with_fake_driver(%{:any => {404, @no_such_element_legacy}})

      assert {:error, %WebDriverError{category: :no_such_element}} =
               RequestUtils.make_req(
                 :post,
                 "session/sid/element",
                 %{using: "css", value: ".x"},
                 %{safe: true},
                 4
               )

      # retries: 4 means 1 initial attempt + 4 retries
      assert FakeWebDriver.request_count(server, "session/sid/element") == 5
    end

    test "uncategorized error is not retried even when safe" do
      server = with_fake_driver(%{:any => {500, @boom}})

      assert {:error, %WebDriverError{category: nil, message: "boom"}} =
               RequestUtils.make_req(
                 :post,
                 "session/sid/element",
                 %{},
                 %{safe: true},
                 4
               )

      assert FakeWebDriver.request_count(server, "session/sid/element") == 1
    end

    test "transport failure is retried for safe commands" do
      # First two accepted connections are dropped without a response,
      # then the driver starts answering normally.
      server = with_fake_driver(%{:any => {200, @value_ok}}, fail_first: 2)

      assert "ok" =
               RequestUtils.make_req(
                 :get,
                 "session/sid/title",
                 %{},
                 %{safe: true},
                 4
               )

      # Two dropped attempts plus the successful one.
      assert FakeWebDriver.request_count(server, "session/sid/title") == 3
    end
  end

  describe "unknown responses fail instead of returning :ok" do
    test "unrecognized json raises a WebDriverError" do
      server = with_fake_driver(%{:any => {200, @unknown_json}})

      assert_raise WebDriverError, ~r/unrecognized driver response/, fn ->
        RequestUtils.make_req(:get, "session/sid/title")
      end

      assert FakeWebDriver.request_count(server, "session/sid/title") == 1
    end
  end

  describe "error shape" do
    test "legacy chrome_driver error keeps driver, message and raw value" do
      raw = @no_such_element_legacy
      server = with_fake_driver(%{:any => {404, raw}})

      err =
        assert_raise WebDriverError, fn ->
          RequestUtils.make_req(:get, "session/sid/element/x/text")
        end

      assert err.driver == :chrome_driver
      assert err.category == :no_such_element
      assert err.status == 404
      assert err.message == "no such element: .foo"
      assert err.value == %{"message" => "no such element: .foo"}
      assert FakeWebDriver.request_count(server, "session/sid/element/x/text") == 1
    end

    test "w3c chrome_driver error is categorized and preserves the payload" do
      server = with_fake_driver(%{:any => {404, @no_such_element_w3c}})

      err =
        assert_raise WebDriverError, fn ->
          RequestUtils.make_req(:get, "session/sid/element/x/text")
        end

      assert err.driver == :chrome_driver
      assert err.category == :no_such_element
      assert err.message == "Unable to locate element"
      assert err.value["error"] == "no such element"
    end
  end
end
