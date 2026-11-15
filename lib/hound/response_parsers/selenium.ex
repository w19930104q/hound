defmodule Hound.ResponseParsers.Selenium do
  @moduledoc false

  use Hound.ResponseParser

  alias Hound.WebDriverError

  # Selenium nests the Java exception class in the error payload.
  def handle_error(%{"class" => "org.openqa.selenium.NoSuchElementException"} = value) do
    {:error, %WebDriverError{
      driver: :selenium,
      category: :no_such_element,
      message: value["message"] || "no such element",
      value: value
    }}
  end

  # W3C Selenium (geckodriver) responses.
  def handle_error(%{"error" => "no such element"} = value) do
    {:error, %WebDriverError{
      driver: :selenium,
      category: :no_such_element,
      message: value["message"] || "no such element",
      value: value
    }}
  end
end
