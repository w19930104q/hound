defmodule Hound.ResponseParsers.ChromeDriver do
  @moduledoc false

  use Hound.ResponseParser

  alias Hound.WebDriverError

  # Legacy ChromeDriver reports the error name inside the message.
  def handle_error(%{"message" => "no such element" <> _rest} = value) do
    categorized_error(value, :no_such_element)
  end

  # W3C ChromeDriver reports a structured "error" field.
  def handle_error(%{"error" => "no such element"} = value) do
    categorized_error(value, :no_such_element)
  end

  defp categorized_error(value, category) do
    {:error, %WebDriverError{
      driver: :chrome_driver,
      category: category,
      message: value["message"] || Atom.to_string(category),
      value: value
    }}
  end
end
