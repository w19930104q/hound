defmodule ResponseParserTest do
  use ExUnit.Case

  alias Hound.ResponseParser
  alias Hound.WebDriverError

  defmodule DummyParser do
    use Hound.ResponseParser
  end

  defmodule DummyCustomErrorParser do
    use Hound.ResponseParser

    def handle_error(%{"message" => "some error"}) do
      "custom handler"
    end
  end

  test "parse/2" do
    body = ~s({"sessionId": 1})
    assert ResponseParser.parse(DummyParser, "session", 200, [], body) == {:ok, 1}
  end

  test "parse/2 with 204 no-content response" do
    assert ResponseParser.parse(DummyParser, "session", 204, [], "") == :ok
  end

  test "parse/2 with invalid json returns a driver error" do
    assert {:error, %WebDriverError{driver: :dummy_parser, value: "not json"}} =
      ResponseParser.parse(DummyParser, "foo", 500, [], "not json")
  end

  test "handle_response/3 session" do
    assert DummyParser.handle_response("session", 200, %{"sessionId" => 1}) == {:ok, 1}
    assert {:error, %WebDriverError{}} =
      DummyParser.handle_response("session", 400, %{"sessionId" => 1})
  end

  test "handle_response/3 errors keep driver, message and raw value" do
    body = %{"value" => %{"message" => "error"}}
    assert {:error, %WebDriverError{
      driver: :dummy_parser,
      message: "error",
      value: %{"message" => "error"}
    }} = DummyParser.handle_response("foo", 200, body)

    # Custom handle_error clauses keep working unchanged.
    body = %{"value" => %{"message" => "some error"}}
    assert DummyCustomErrorParser.handle_response("foo", 200, body) == "custom handler"

    body = %{"value" => %{"message" => "other error"}}
    assert {:error, %WebDriverError{message: "other error"}} =
      DummyCustomErrorParser.handle_response("foo", 200, body)
  end

  test "handle_response/3 w3c error payload" do
    body = %{"value" => %{"error" => "no such window", "message" => "gone"}}
    assert {:error, %WebDriverError{
      driver: :dummy_parser,
      message: "gone",
      value: %{"error" => "no such window", "message" => "gone"}
    }} = DummyParser.handle_response("foo", 404, body)
  end

  test "handle_response/3 legacy status value" do
    assert DummyParser.handle_response("foo", 200, %{"status" => 0, "value" => "value"}) == "value"
  end

  test "handle_response/3 legacy non zero status is an error, not a value" do
    body = %{"status" => 7, "value" => %{"message" => "no such element: x"}}

    assert {:error, %WebDriverError{
      driver: :dummy_parser,
      message: "no such element: x",
      value: %{"message" => "no such element: x"}
    }} = DummyParser.handle_response("foo", 200, body)
  end

  test "handle_response/3 w3c success value" do
    assert DummyParser.handle_response("foo", 200, %{"value" => "value"}) == "value"
  end

  test "handle_response/3 plain map success returns the map" do
    assert DummyParser.handle_response("foo", 200, %{"hello" => "world"}) == %{"hello" => "world"}
  end

  test "handle_response/3 unknown json with success code no longer returns :ok" do
    assert {:error, %WebDriverError{message: "unrecognized driver response"}} =
      DummyParser.handle_response("foo", 200, ["unexpected"])
  end

  test "handle_response/3 http error" do
    assert {:error, %WebDriverError{status: 500}} =
      DummyParser.handle_response("foo", 500, %{"bogus" => true})
  end
end
