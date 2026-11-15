defmodule Hound.SessionServerTest do
  use ExUnit.Case, async: false

  import Hound.Helpers.Session

  alias Hound.FakeWebDriver
  alias Hound.SessionServer

  setup do
    previous_driver_info = Agent.get(Hound.ConnectionServer, & &1.driver_info)
    previous_retry_time = Application.get_env(:hound, :retry_time)
    Application.put_env(:hound, :retry_time, 10)

    # Not linked to (or supervised by) the test process, so the fake
    # webdriver is still alive when on_exit and :DOWN cleanups run.
    {:ok, wd} = FakeWebDriver.start()
    port = FakeWebDriver.port(wd)

    Agent.update(Hound.ConnectionServer, fn state ->
      driver_info = %{state.driver_info | host: "http://127.0.0.1", port: port, path_prefix: nil}
      %{state | driver_info: driver_info}
    end)

    test_pid = self()

    on_exit(fn ->
      Hound.end_session(test_pid)

      Agent.update(Hound.ConnectionServer, fn state ->
        %{state | driver_info: previous_driver_info}
      end)

      if previous_retry_time do
        Application.put_env(:hound, :retry_time, previous_retry_time)
      else
        Application.delete_env(:hound, :retry_time)
      end

      FakeWebDriver.stop(wd)
    end)

    {:ok, wd: wd}
  end

  test "start, switch and explicit end delete every session exactly once", %{wd: wd} do
    start_session()
    change_session_to(:other)
    in_browser_session(:third, fn -> :ok end)

    assert %{default: _, other: _, third: _} = SessionServer.all_sessions_for_pid(self())
    assert length(FakeWebDriver.snapshot(wd).created) == 3

    end_session()

    snapshot = FakeWebDriver.snapshot(wd)
    assert Enum.sort(snapshot.deletes) == Enum.sort(snapshot.created)
    assert SessionServer.all_sessions_for_pid(self()) == %{}

    # end_session is idempotent: no further deletes are issued
    end_session()
    assert FakeWebDriver.snapshot(wd).deletes == snapshot.deletes
    assert :sys.get_state(SessionServer) == %{}
  end

  test "sessions are destroyed exactly once when the owner process is killed", %{wd: wd} do
    test_pid = self()

    {:ok, pid} =
      Task.start(fn ->
        start_session()
        change_session_to(:extra)
        send(test_pid, :session_started)
        Process.sleep(:infinity)
      end)

    assert_receive :session_started
    assert %{default: _, extra: _} = SessionServer.all_sessions_for_pid(pid)
    created = FakeWebDriver.snapshot(wd).created
    assert length(created) == 2

    Process.exit(pid, :kill)

    assert eventually(fn ->
             snapshot = FakeWebDriver.snapshot(wd)
             Enum.sort(snapshot.deletes) == Enum.sort(created)
           end)

    # No state is left behind for the dead process
    assert eventually(fn -> SessionServer.all_sessions_for_pid(pid) == %{} end)
    assert eventually(fn -> :sys.get_state(SessionServer) == %{} end)

    # The deletes must not be re-issued after the fact
    deletes = FakeWebDriver.snapshot(wd).deletes
    Process.sleep(50)
    assert FakeWebDriver.snapshot(wd).deletes == deletes
  end

  test "concurrent processes each get their sessions deleted exactly once", %{wd: wd} do
    count = 20

    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          start_session()
          change_session_to(:extra)
          end_session()
        end)
      end

    Enum.each(tasks, &Task.await(&1, 30_000))

    assert eventually(fn ->
             snapshot = FakeWebDriver.snapshot(wd)
             length(snapshot.created) == count * 2 && length(snapshot.deletes) == count * 2
           end)

    snapshot = FakeWebDriver.snapshot(wd)
    assert Enum.sort(snapshot.deletes) == Enum.sort(snapshot.created)
    assert length(Enum.uniq(snapshot.deletes)) == count * 2

    # No stale mappings remain, in ETS or in the server state
    assert eventually(fn -> :ets.info(SessionServer, :size) == 0 end)
    assert eventually(fn -> :sys.get_state(SessionServer) == %{} end)
  end

  test "failed deletes are retried and never touch newer sessions", %{wd: wd} do
    start_session()
    first_id = Hound.current_session_id()

    FakeWebDriver.fail_next_deletes(wd, 2)
    end_session()

    # Two failed attempts plus the successful retry, all for the same id
    assert FakeWebDriver.snapshot(wd).deletes == [first_id, first_id, first_id]
    assert SessionServer.all_sessions_for_pid(self()) == %{}

    # A session created afterwards by the same process is unaffected
    start_session()
    second_id = Hound.current_session_id()
    assert second_id != first_id
    end_session()

    assert FakeWebDriver.snapshot(wd).deletes == [first_id, first_id, first_id, second_id]
  end

  test "delete retries also apply when the owner process dies", %{wd: wd} do
    test_pid = self()

    {:ok, pid} =
      Task.start(fn ->
        start_session()
        send(test_pid, :session_started)
        Process.sleep(:infinity)
      end)

    assert_receive :session_started
    [session_id] = FakeWebDriver.snapshot(wd).created

    FakeWebDriver.fail_next_deletes(wd, 1)
    Process.exit(pid, :kill)

    assert eventually(fn -> FakeWebDriver.snapshot(wd).deletes == [session_id, session_id] end)
    assert eventually(fn -> :sys.get_state(SessionServer) == %{} end)
  end

  test "a failed session creation raises in the caller and leaves no state behind", %{wd: wd} do
    FakeWebDriver.fail_next_creates(wd, 1)

    assert_raise RuntimeError, ~r/could not create a new session/, fn -> start_session() end

    assert SessionServer.all_sessions_for_pid(self()) == %{}
    assert :sys.get_state(SessionServer) == %{}

    # The server survives and can create sessions again
    start_session()
    assert Hound.current_session_id() in FakeWebDriver.snapshot(wd).created
  end

  test "in_browser_session switches back to the previous session when the function raises" do
    start_session()
    change_session_to(:first)

    assert_raise RuntimeError, "boom", fn ->
      in_browser_session(:second, fn -> raise "boom" end)
    end

    assert current_session_name() == :first
  end

  defp eventually(fun, retries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, retries - 1)
    end
  end
end
