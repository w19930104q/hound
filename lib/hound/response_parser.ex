defmodule Hound.ResponseParser do
  @moduledoc """
  Defines a behaviour for parsing driver responses
  and provides a default implementation of the behaviour
  """

  require Logger

  alias Hound.WebDriverError

  @callback handle_response(any, integer, String.t) :: any
  @callback handle_error(map) :: {:error, any}

  defmacro __using__(_) do
    quote do
      @behaviour Hound.ResponseParser

      @before_compile unquote(__MODULE__)

      def handle_response(path, code, body) do
        Hound.ResponseParser.handle_response(__MODULE__, path, code, body)
      end

      defdelegate warning?(message), to: Hound.ResponseParser

      defoverridable [handle_response: 3, warning?: 1]
    end
  end

  @doc """
  Parses a raw driver response.

  Bodies that are not valid JSON or do not match any known response
  shape result in a `Hound.WebDriverError` instead of a bare `:error`
  or a misleading `:ok`.
  """
  def parse(parser, path, code, _headers, raw_content) do
    case decode_content(raw_content) do
      {:ok, body} -> parser.handle_response(path, code, body)
      {:error, reason} ->
        {:error, build_error(parser, code, raw_content,
                 "could not decode driver response: #{inspect(reason)}")}
    end
  end

  # Don't try to parse the json because there is none.
  def handle_response(_parser, _path, 204, %{}), do: :ok

  @doc """
  Default implementation to handle drivers responses.
  """
  def handle_response(mod, path, code, body)
  def handle_response(_mod, "session", code, %{"sessionId" => session_id}) when code < 300 do
    {:ok, session_id}
  end

  # W3C WebDriver error: {"value": {"error": "...", "message": "...", ...}}
  def handle_response(mod, _path, code, %{"value" => %{"error" => _error_name} = value}) do
    handle_driver_error(mod, code, value)
  end

  # Legacy JSON wire protocol error: {"value": {"message": "..."}}
  def handle_response(mod, _path, _code, %{"value" => %{"message" => message} = value}) do
    if mod.warning?(message) do
      Logger.warn(message)
      message
    else
      handle_driver_error(mod, value)
    end
  end

  # Legacy JSON wire protocol success with a status code.
  def handle_response(_mod, _path, _code, %{"status" => 0, "value" => value}), do: value

  # Legacy JSON wire protocol error with a non zero status code.
  def handle_response(mod, _path, code, %{"status" => status, "value" => value})
      when is_integer(status) and status != 0 do
    case value do
      %{} = payload ->
        case mod.handle_error(payload) do
          {:error, %WebDriverError{} = err} -> {:error, %{err | status: err.status || code}}
          other -> other
        end

      _ ->
        {:error, build_error(mod, code, value, "driver returned status #{status}")}
    end
  end

  # W3C WebDriver success: {"value": ...}
  def handle_response(_mod, _path, code, %{"value" => value}) when code < 400, do: value

  # A 2xx/3xx response without a recognizable payload is still valid
  # (some endpoints answer with an empty JSON object/list).
  def handle_response(_mod, _path, code, body) when code < 400 and is_map(body) do
    body
  end

  # Anything else is an error: unknown JSON shape or an HTTP 4xx/5xx.
  def handle_response(mod, _path, code, body) do
    {:error, build_error(mod, code, body, "unrecognized driver response")}
  end

  defp handle_driver_error(mod, value) do
    mod.handle_error(value)
  end

  defp handle_driver_error(mod, code, value) do
    case mod.handle_error(value) do
      {:error, %WebDriverError{} = err} -> {:error, %{err | status: code}}
      other -> other
    end
  end

  @doc """
  Builds a `Hound.WebDriverError` keeping the driver, message, HTTP
  status and raw payload, so callers always get one error shape.
  """
  def build_error(parser, status, value, message) when is_atom(parser) do
    %WebDriverError{
      driver: driver_name(parser),
      status: status,
      value: value,
      message: message
    }
  end

  defp driver_name(Hound.ResponseParsers.ChromeDriver), do: :chrome_driver
  defp driver_name(Hound.ResponseParsers.Selenium), do: :selenium
  defp driver_name(Hound.ResponseParsers.PhantomJs), do: :phantomjs
  defp driver_name(other), do: other |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

  @doc """
  Default implementation to check if the message is a warning
  """
  def warning?(message) do
    Regex.match?(~r/#{Regex.escape("not clickable")}/, message)
  end

  @doc """
  Decodes a response body
  """
  def decode_content([]), do: Map.new
  def decode_content(""), do: {:ok, %{}}
  def decode_content(content), do: Jason.decode(content)

  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Fallback case if we did not match the message in the using module.
      Returns a `Hound.WebDriverError` so every driver error carries the
      driver name, message and raw value.
      """
      def handle_error(response) do
        message =
          case response do
            %{"message" => message} when is_binary(message) -> message
            %{"error" => error} when is_binary(error) -> error
            _ -> inspect(response)
          end

        {:error,
         Hound.ResponseParser.build_error(__MODULE__, nil, response, message)}
      end
    end
  end
end
