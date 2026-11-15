defmodule Hound.ResponseParsers.PhantomJs do
  @moduledoc false

  use Hound.ResponseParser

  alias Hound.WebDriverError

  # PhantomJS wraps a JSON encoded error inside the "message" field.
  def handle_error(%{"message" => message} = value) do
    decoded =
      case Jason.decode(message) do
        {:ok, decoded_error} -> decoded_error
        _ -> value
      end

    do_handle_error(decoded, value)
  end

  defp do_handle_error(%{"errorMessage" => "Unable to find element" <> _rest} = decoded, raw) do
    {:error, %WebDriverError{
      driver: :phantomjs,
      category: :no_such_element,
      message: decoded["errorMessage"],
      value: raw
    }}
  end

  defp do_handle_error(%{"errorMessage" => msg}, raw) do
    {:error, %WebDriverError{
      driver: :phantomjs,
      message: msg,
      value: raw
    }}
  end

  defp do_handle_error(err, raw) do
    {:error, Hound.ResponseParser.build_error(__MODULE__, nil, raw, inspect(err))}
  end
end
