defmodule Hound.ResponseParsersTest do
  use ExUnit.Case

  alias Hound.ResponseParsers.ChromeDriver
  alias Hound.ResponseParsers.PhantomJs
  alias Hound.ResponseParsers.Selenium
  alias Hound.WebDriverError

  describe "ChromeDriver" do
    test "legacy message based no such element" do
      value = %{"message" => "no such element: cannot find .foo"}

      assert {:error, %WebDriverError{
        driver: :chrome_driver,
        category: :no_such_element,
        message: "no such element: cannot find .foo",
        value: ^value
      }} = ChromeDriver.handle_error(value)
    end

    test "w3c structured no such element" do
      value = %{"error" => "no such element", "message" => "Unable to locate element"}

      assert {:error, %WebDriverError{
        driver: :chrome_driver,
        category: :no_such_element,
        message: "Unable to locate element"
      }} = ChromeDriver.handle_error(value)
    end

    test "unclassified error falls back to the common shape" do
      assert {:error, %WebDriverError{
        driver: :chrome_driver,
        category: nil,
        message: "unknown boom",
        value: %{"message" => "unknown boom"}
      }} = ChromeDriver.handle_error(%{"message" => "unknown boom"})
    end
  end

  describe "Selenium" do
    test "nested Java exception class is categorized" do
      value = %{
        "class" => "org.openqa.selenium.NoSuchElementException",
        "message" => "nested failure"
      }

      assert {:error, %WebDriverError{
        driver: :selenium,
        category: :no_such_element,
        message: "nested failure",
        value: ^value
      }} = Selenium.handle_error(value)
    end

    test "w3c geckodriver error is categorized" do
      value = %{"error" => "no such element", "message" => "no node"}

      assert {:error, %WebDriverError{
        driver: :selenium,
        category: :no_such_element,
        message: "no node"
      }} = Selenium.handle_error(value)
    end

    test "unclassified nested error keeps the raw payload" do
      value = %{"class" => "org.openqa.selenium.TimeoutException", "message" => "slow"}

      assert {:error, %WebDriverError{
        driver: :selenium,
        category: nil,
        message: "slow",
        value: ^value
      }} = Selenium.handle_error(value)
    end
  end

  describe "PhantomJS" do
    test "json encoded errorMessage for missing element is categorized" do
      inner = Jason.encode!(%{"errorMessage" => "Unable to find element with id x"})
      value = %{"message" => inner}

      assert {:error, %WebDriverError{
        driver: :phantomjs,
        category: :no_such_element,
        message: "Unable to find element with id x",
        value: ^value
      }} = PhantomJs.handle_error(value)
    end

    test "other errorMessage is preserved" do
      inner = Jason.encode!(%{"errorMessage" => "frame gone"})
      value = %{"message" => inner}

      assert {:error, %WebDriverError{
        driver: :phantomjs,
        category: nil,
        message: "frame gone",
        value: ^value
      }} = PhantomJs.handle_error(value)
    end

    test "non json message falls back to inspectable payload" do
      value = %{"message" => "plain text failure"}

      assert {:error, %WebDriverError{
        driver: :phantomjs,
        category: nil,
        value: ^value
      }} = PhantomJs.handle_error(value)
    end
  end
end
