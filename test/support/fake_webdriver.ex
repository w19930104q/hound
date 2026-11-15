defmodule Hound.FakeWebDriver do
  @moduledoc """
  A minimal in-process WebDriver stand-in, used to test Hound's session
  lifecycle (create / switch / end / owner exit) without a real browser.

  It records every created and deleted session id, and can be told to fail
  the next N create or delete requests to exercise retry behaviour.
  """
  use GenServer

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  def stop(server) do
    GenServer.stop(server, :normal, 5000)
  end

  def port(server), do: GenServer.call(server, :port)

  @doc "Returns `%{created: [...], deletes: [...]}` in request order."
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Fail the next `n` session create requests with a 500 response."
  def fail_next_creates(server, n), do: GenServer.call(server, {:fail_next, :creates, n})

  @doc "Fail the next `n` session delete requests with a 500 response."
  def fail_next_deletes(server, n), do: GenServer.call(server, {:fail_next, :deletes, n})

  ## GenServer callbacks

  def init(_opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    server = self()
    spawn_link(fn -> accept_loop(listen, server) end)

    state = %{
      listen: listen,
      port: port,
      created: [],
      deletes: [],
      fail_creates: 0,
      fail_deletes: 0,
      next_id: 0
    }

    {:ok, state}
  end

  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{created: Enum.reverse(state.created), deletes: Enum.reverse(state.deletes)}
    {:reply, snapshot, state}
  end

  def handle_call({:fail_next, :creates, n}, _from, state) do
    {:reply, :ok, %{state | fail_creates: n}}
  end

  def handle_call({:fail_next, :deletes, n}, _from, state) do
    {:reply, :ok, %{state | fail_deletes: n}}
  end

  def handle_call({:dispatch, method, path, _body}, _from, state) do
    {status, body, state} = route(method, path, state)
    {:reply, {status, body}, state}
  end

  defp route(:post, "session", state) do
    if state.fail_creates > 0 do
      {500, error_body("simulated create failure"), %{state | fail_creates: state.fail_creates - 1}}
    else
      id = "fake-session-#{state.next_id}"
      state = %{state | next_id: state.next_id + 1, created: [id | state.created]}
      {200, ~s({"status":0,"sessionId":"#{id}","value":{}}), state}
    end
  end

  defp route(:delete, "session/" <> id, state) do
    state = %{state | deletes: [id | state.deletes]}

    if state.fail_deletes > 0 do
      {500, error_body("simulated delete failure"), %{state | fail_deletes: state.fail_deletes - 1}}
    else
      {200, ~s({"status":0,"value":null}), state}
    end
  end

  defp route(_method, _path, state) do
    {200, ~s({"status":0,"value":null}), state}
  end

  defp error_body(message) do
    ~s({"status":13,"value":{"message":"#{message}"}})
  end

  ## Minimal HTTP/1.1 handling

  defp accept_loop(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> handle_connection(socket, server) end)
        accept_loop(listen, server)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_connection(socket, server) do
    :inet.setopts(socket, packet: :http_bin)

    case read_request(socket) do
      {:ok, method, path, headers} ->
        body = read_body(socket, content_length(headers))
        {status, response_body} = GenServer.call(server, {:dispatch, method, path, body})
        send_response(socket, status, response_body)

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, {:http_request, method, {:abs_path, path}, _version}} <- :gen_tcp.recv(socket, 0, 5000),
         {:ok, headers} <- read_headers(socket, []) do
      method = method |> to_string() |> String.downcase() |> String.to_atom()
      path = path |> to_string() |> String.trim_leading("/") |> String.split("?") |> hd()
      {:ok, method, path, headers}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, :http_eoh} -> {:ok, acc}
      {:ok, {:http_header, _, name, _, value}} -> read_headers(socket, [{name, value} | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_length(headers) do
    Enum.find_value(headers, 0, fn
      {name, value} when name in [:"Content-Length", "Content-Length", "content-length"] ->
        String.to_integer(to_string(value))

      _ ->
        nil
    end)
  end

  defp read_body(_socket, 0), do: ""

  defp read_body(socket, length) do
    :inet.setopts(socket, packet: :raw)

    case :gen_tcp.recv(socket, length, 5000) do
      {:ok, body} -> body
      {:error, _reason} -> ""
    end
  end

  defp send_response(socket, status, body) do
    reason = if status == 200, do: "OK", else: "Internal Server Error"

    response = [
      "HTTP/1.1 ", Integer.to_string(status), " ", reason, "\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: ", Integer.to_string(byte_size(body)), "\r\n",
      "Connection: close\r\n",
      "\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end
end


