defmodule Hound.FakeWebDriver do
  @moduledoc """
  A tiny in-process WebDriver used by the request boundary tests.

  It speaks just enough HTTP/1.1 for hackney and records every request
  it receives, so tests can assert on the number of times a command was
  actually submitted.

  Script responses by path prefix in `responses`:

      {:ok, server} = Hound.FakeWebDriver.start_link(
        responses: %{"session" => {200, ~s({"sessionId":"abc"})}}
      )

  The `:any` key is the fallback. `fail_first: n` closes the first `n`
  accepted connections without answering, emulating a dead/unreachable
  driver so transport failures can be exercised deterministically.
  """

  use Agent

  def start_link(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          requests: [],
          responses: Keyword.get(opts, :responses, %{}),
          failures_remaining: Keyword.get(opts, :fail_first, 0)
        }
      end)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()

    if Keyword.get(opts, :refuse, false) do
      # Keep the socket bound but never accept: clients fail at the
      # transport level (connection timeout) like an unreachable driver.
      spawn_link(fn ->
        if Process.alive?(parent), do: Process.sleep(:infinity)
      end)
    else
      spawn_link(fn -> accept_loop(listen_socket, agent, parent) end)
    end

    {:ok, %{agent: agent, socket: listen_socket, port: port,
            url: "http://localhost:#{port}"}}
  end

  defp accept_loop(listen_socket, agent, parent) do
    case :gen_tcp.accept(listen_socket, 500) do
      {:ok, socket} ->
        spawn(fn -> handle_connection(socket, agent) end)
        accept_loop(listen_socket, agent, parent)

      {:error, :timeout} ->
        if Process.alive?(parent), do: accept_loop(listen_socket, agent, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle_connection(socket, agent) do
    with {:ok, {method, path, headers, body}} <- read_request(socket) do
      record_request(agent, method, path, body)
      state = Agent.get(agent, & &1)

      if state.failures_remaining > 0 do
        Agent.update(agent, fn s ->
          %{s | failures_remaining: s.failures_remaining - 1}
        end)

        # No response at all: hackney reports this as a transport
        # failure, exactly like an unreachable driver.
        :gen_tcp.close(socket)
      else
        {status, payload} = respond(state.responses, path)
        :ok = write_response(socket, status, payload)
        :gen_tcp.close(socket)
      end
    else
      _ -> :gen_tcp.close(socket)
    end
  end

  # Reads a full HTTP/1.1 request (request line + headers + body).
  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, chunk} ->
        data = acc <> chunk

        case :erlang.decode_packet(:http_bin, data, []) do
          {:more, _} ->
            read_request(socket, data)

          {:ok, {:http_request, method, {:abs_path, path}, _}, rest} ->
            read_headers(socket, data, rest, method, path, [])
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_headers(socket, raw, rest, method, path, headers) do
    case :erlang.decode_packet(:httph_bin, rest, []) do
      {:more, _} ->
        case :gen_tcp.recv(socket, 0, 1000) do
          {:ok, chunk} -> read_headers(socket, raw, rest <> chunk, method, path, headers)
          error -> error
        end

      {:ok, {:http_header, _, name, _, value}, rest} ->
        read_headers(socket, raw, rest, method, path, [{name, value} | headers])

      {:ok, :http_eoh, rest} ->
        with {:ok, body} <- read_body(socket, rest, headers) do
          {:ok, {method, to_string(path), Enum.reverse(headers), body}}
        end
    end
  end

  defp read_body(socket, rest, headers) do
    length = content_length(headers)

    cond do
      length == 0 ->
        {:ok, ""}

      byte_size(rest) >= length ->
        {:ok, :binary.part(rest, 0, length)}

      true ->
        read_remaining_body(socket, rest, length)
    end
  end

  defp read_remaining_body(socket, acc, length) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, chunk} ->
        data = acc <> chunk

        if byte_size(data) >= length do
          {:ok, :binary.part(data, 0, length)}
        else
          read_remaining_body(socket, data, length)
        end

      error ->
        error
    end
  end

  defp content_length(headers) do
    Enum.find_value(headers, 0, fn
      {~c"Content-Length", value} -> String.to_integer(to_string(value))
      _ -> false
    end)
  end

  defp record_request(agent, method, path, body) do
    method = method |> Atom.to_string() |> String.downcase() |> String.to_atom()

    Agent.update(agent, fn s ->
      %{s | requests: s.requests ++ [%{method: method, path: path, body: body}]}
    end)
  end

  defp respond(responses, path) do
    keys = Map.keys(responses)
    bare_path = String.trim_leading(path, "/")

    cond do
      # Exact path match always wins.
      bare_path in keys ->
        Map.fetch!(responses, bare_path)

      prefix = prefix_match(keys, path) ->
        Map.fetch!(responses, prefix)

      true ->
        Map.fetch!(responses, :any)
    end
  end

  # Most specific registered prefix. A bare "session" key must not
  # shadow "session/sid" style paths, so a trailing slash is required.
  defp prefix_match(keys, path) do
    keys
    |> Enum.reject(&(&1 == :any))
    |> Enum.filter(&String.starts_with?(path, "/#{&1}/"))
    |> Enum.max_by(&byte_size/1, fn -> nil end)
  end

  defp write_response(socket, status, payload) do
    response =
      [
        "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: #{byte_size(payload)}\r\n",
        "Connection: close\r\n\r\n",
        payload
      ]

    :gen_tcp.send(socket, response)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(204), do: "No Content"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_), do: "Error"

  @doc "All requests received, in order, as %{method, path, body}"
  def requests(%{agent: agent}) do
    Agent.get(agent, & &1.requests)
  end

  @doc "Number of requests received for a path prefix"
  def request_count(server, path_prefix) do
    server
    |> requests()
    |> Enum.count(&String.starts_with?(&1.path, "/#{path_prefix}"))
  end

  def stop(%{socket: socket, agent: agent}) do
    if Port.info(socket), do: :gen_tcp.close(socket)
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end
end
