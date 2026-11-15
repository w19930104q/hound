defmodule Hound.RequestUtils do
  @moduledoc false

  alias Hound.WebDriverError

  # Only two situations may be replayed:
  #
  #   * the request never reached the driver (transport failure), so no
  #     effect could have happened server side;
  #   * an explicitly safe read-only command got a categorized driver
  #     error (e.g. element lookup racing with page load).
  #
  # Commands that change session state (create/destroy session,
  # navigation, clicks, ...) are never submitted twice.
  def make_req(type, path, params \\ %{}, options \\ %{}, retries \\ retries())
  def make_req(type, path, params, options, 0) do
    send_req(type, path, params, options)
  end
  def make_req(type, path, params, options, retries) when retries > 0 do
    case send_req(type, path, params, options) do
      {:error, %WebDriverError{} = err} ->
        if retriable?(err, options) do
          make_retry(type, path, params, options, retries)
        else
          {:error, err}
        end

      other ->
        other
    end
  end

  defp retriable?(%WebDriverError{transport: true}, _options), do: true
  defp retriable?(%WebDriverError{category: nil}, _options), do: false
  defp retriable?(%WebDriverError{}, options), do: !!options[:safe]

  defp make_retry(type, path, params, options, retries) do
    :timer.sleep(Application.get_env(:hound, :retry_time, 250))
    make_req(type, path, params, options, retries - 1)
  end

  defp send_req(type, path, params, options) do
    url = get_url(path)
    has_body = params != %{} && type == :post
    {headers, body} = cond do
       has_body && options[:json_encode] != false ->
        {[{"Content-Type", "text/json"}], Jason.encode!(params)}
      has_body ->
        {[], params}
      true ->
        {[], ""}
    end

    :hackney.request(type, url, headers, body, [:with_body | http_options()])
    |> handle_response({url, path, type}, options)
  end

  defp handle_response({:ok, code, headers, body}, {_url, path, _type}, options) do
    case Hound.ResponseParser.parse(response_parser(), path, code, headers, body) do
      {:error, %WebDriverError{} = err} ->
        err = %{err | status: err.status || code}
        if options[:safe],
          do: {:error, err},
          else: raise err

      response -> response
    end
  end

  defp handle_response({:error, reason}, _, _) do
    # Transport level failure. The `:transport` flag marks that the
    # request never got a response, so it is the only failure that may
    # be replayed for state changing commands.
    {:error, %WebDriverError{
      driver: driver_name(),
      transport: true,
      message: "webdriver request failed: #{inspect(reason)}",
      value: reason
    }}
  end

  defp response_parser do
    {:ok, driver_info} = Hound.driver_info()

    case {driver_info.driver, driver_info.browser} do
      {"selenium", "chrome" <> _headless} ->
        Hound.ResponseParsers.ChromeDriver

      {"selenium", _} ->
        Hound.ResponseParsers.Selenium

      {"chrome_driver", _} ->
        Hound.ResponseParsers.ChromeDriver

      {"phantomjs", _} ->
        Hound.ResponseParsers.PhantomJs

      other_driver ->
        raise "No response parser found for #{other_driver}"
    end
  end

  defp driver_name do
    {:ok, driver_info} = Hound.driver_info()
    String.to_atom(driver_info.driver)
  end

  defp get_url(path) do
    {:ok, driver_info} = Hound.driver_info

    host = driver_info[:host]
    port = driver_info[:port]
    path_prefix = driver_info[:path_prefix]

    "#{host}:#{port}/#{path_prefix}#{path}"
  end

  defp http_options() do
    Application.get_env(:hound, :http, [])
  end

  defp retries() do
    Application.get_env(:hound, :retries, 0)
  end
end
