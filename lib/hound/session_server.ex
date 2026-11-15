defmodule Hound.SessionServer do
  @moduledoc false

  use GenServer
  require Logger

  @name __MODULE__

  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end


  def session_for_pid(pid, opts) do
    current_session_id(pid) ||
      change_current_session_for_pid(pid, :default, opts)
  end


  def current_session_id(pid) do
    case :ets.lookup(@name, pid) do
      [{^pid, _ref, session_id, _all_sessions}] -> session_id
      [] -> nil
    end
  end

  def current_session_name(pid) do
    case :ets.lookup(@name, pid) do
      [{^pid, _ref, session_id, all_sessions}] ->
        Enum.find_value all_sessions, fn
          {name, id} when id == session_id -> name
          _ -> nil
        end
      [] -> nil
    end
  end


  def change_current_session_for_pid(pid, session_name, opts) do
    case GenServer.call(@name, {:change_session, pid, session_name, opts}, genserver_timeout()) do
      {:ok, session_id} ->
        session_id

      {:error, reason} ->
        raise "could not create a new session: #{inspect(reason)}, check webdriver is running"
    end
  end


  def all_sessions_for_pid(pid) do
    case :ets.lookup(@name, pid) do
      [{^pid, _ref, _session_id, all_sessions}] -> all_sessions
      [] -> %{}
    end
  end


  def destroy_sessions_for_pid(pid) do
    GenServer.call(@name, {:destroy_sessions, pid}, genserver_timeout())
  end

  ## Callbacks

  def init(state) do
    :ets.new(@name, [:set, :named_table, :protected, read_concurrency: true])
    {:ok, state}
  end


  def handle_call({:change_session, pid, session_name, opts}, _from, state) do
    {reply, state} =
      try do
        change_session(pid, session_name, opts, state)
      rescue
        error -> {{:error, Exception.message(error)}, state}
      catch
        :exit, reason -> {{:error, reason}, state}
        kind, reason -> {{:error, {kind, reason}}, state}
      end

    {:reply, reply, state}
  end

  def handle_call({:destroy_sessions, pid}, _from, state) do
    {:reply, :ok, destroy_sessions(pid, state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      case state do
        %{^ref => ^pid} -> destroy_sessions(pid, state)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp change_session(pid, session_name, opts, state) do
    {:ok, driver_info} = Hound.driver_info

    {ref, sessions, fresh?} =
      case :ets.lookup(@name, pid) do
        [{^pid, ref, _session_id, sessions}] ->
          {ref, sessions, false}
        [] ->
          {Process.monitor(pid), %{}, true}
      end

    case Map.fetch(sessions, session_name) do
      {:ok, session_id} ->
        :ets.insert(@name, {pid, ref, session_id, sessions})
        {{:ok, session_id}, Map.put(state, ref, pid)}

      :error ->
        case create_session(driver_info, opts) do
          {:ok, session_id} ->
            sessions = Map.put(sessions, session_name, session_id)
            :ets.insert(@name, {pid, ref, session_id, sessions})
            {{:ok, session_id}, Map.put(state, ref, pid)}

          {:error, reason} ->
            # The session was never registered, so a failed create must
            # not leave a monitor behind for an otherwise unknown pid.
            if fresh?, do: Process.demonitor(ref, [:flush])
            {{:error, reason}, state}
        end
    end
  end

  defp create_session(driver_info, opts) do
    case Hound.Session.create_session(driver_info[:browser], opts) do
      {:ok, session_id} -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  # Single teardown path, shared by `end_session` and the `:DOWN` handler.
  # All state for the pid is removed before any webdriver request is made,
  # so every session is deleted exactly once, no matter how many times this
  # runs for the same pid.
  defp destroy_sessions(pid, state) do
    case :ets.lookup(@name, pid) do
      [{^pid, ref, _session_id, sessions}] ->
        :ets.delete(@name, pid)
        Process.demonitor(ref, [:flush])
        delete_sessions(sessions)
        Map.delete(state, ref)

      [] ->
        state
    end
  end

  defp delete_sessions(sessions) do
    Enum.each sessions, fn({_session_name, session_id})->
      case delete_session(session_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to destroy Hound session #{session_id}: #{inspect(reason)}")
      end
    end
  end

  # Deletes a single session, retrying failed requests. Only ever targets
  # the given session id, so retries can never touch sessions created later
  # by the same (or a reused) process.
  defp delete_session(session_id) do
    case Hound.Session.destroy_session(session_id, retries: destroy_session_retries()) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  defp destroy_session_retries() do
    Application.get_env(:hound, :destroy_session_retries, 3)
  end

  defp genserver_timeout() do
    Application.get_env(:hound, :genserver_timeout, 60000)
  end
end
