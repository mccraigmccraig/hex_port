defmodule DoubleDown.TestingTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Test.Greeter
  alias DoubleDown.Test.Counter

  # ── handler registration API ──────────────────────────────

  describe "set_handler/2" do
    test "returns :ok" do
      assert :ok = DoubleDown.Testing.set_handler(Greeter, Greeter.Impl)
    end

    test "registered module handler is used by dispatch" do
      DoubleDown.Testing.set_handler(Greeter, Greeter.Impl)
      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
    end
  end

  describe "set_stateless_handler/2" do
    test "returns :ok" do
      assert :ok =
               DoubleDown.Testing.set_stateless_handler(Greeter, fn
                 _contract, :greet, [name] -> "fn: #{name}"
               end)
    end

    test "registered fn handler is used by dispatch" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "fn: #{name}"
      end)

      assert "fn: Bob" = Greeter.Port.greet("Bob")
    end

    test "rejects non-arity-3 function" do
      assert_raise FunctionClauseError, fn ->
        DoubleDown.Testing.set_stateless_handler(Greeter, fn _ -> :bad end)
      end
    end
  end

  describe "set_stateful_handler/3" do
    test "returns :ok" do
      assert :ok =
               DoubleDown.Testing.set_stateful_handler(
                 Counter,
                 fn _contract, :increment, [n], state -> {state + n, state + n} end,
                 0
               )
    end

    test "initial state is available on first dispatch" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :get_count, [], state -> {state, state}
        end,
        42
      )

      assert 42 = Counter.Port.get_count()
    end

    test "state persists across dispatches" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :increment, [n], state -> {state + n, state + n}
          _contract, :get_count, [], state -> {state, state}
        end,
        0
      )

      Counter.Port.increment(10)
      Counter.Port.increment(5)
      assert 15 = Counter.Port.get_count()
    end

    test "rejects non-arity-4 function" do
      assert_raise FunctionClauseError, fn ->
        DoubleDown.Testing.set_stateful_handler(Counter, fn _, _, _ -> {:ok, 0} end, 0)
      end
    end
  end

  # ── handler replacement ───────────────────────────────────

  describe "handler overwrite protection" do
    test "raises when setting fn handler over existing fn handler" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "first: #{name}"
      end)

      assert_raise ArgumentError, ~r/A handler is already installed/, fn ->
        DoubleDown.Testing.set_stateless_handler(Greeter, fn
          _contract, :greet, [name] -> "second: #{name}"
        end)
      end
    end

    test "raises when setting module handler over existing fn handler" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "fn: #{name}"
      end)

      assert_raise ArgumentError, ~r/A handler is already installed/, fn ->
        DoubleDown.Testing.set_handler(Greeter, Greeter.Impl)
      end
    end

    test "raises when setting stateful handler over existing module handler" do
      DoubleDown.Testing.set_handler(Counter, Greeter.Impl)

      assert_raise ArgumentError, ~r/A handler is already installed/, fn ->
        DoubleDown.Testing.set_stateful_handler(
          Counter,
          fn
            _contract, :increment, [n], state -> {state + n, state + n}
            _contract, :get_count, [], state -> {state, state}
          end,
          100
        )
      end
    end

    test "reset then reinstall works" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "first: #{name}"
      end)

      assert "first: X" = Greeter.Port.greet("X")

      DoubleDown.Testing.reset()

      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "second: #{name}"
      end)

      assert "second: X" = Greeter.Port.greet("X")
    end
  end

  # ── reset/0 ───────────────────────────────────────────────

  describe "reset/0" do
    test "returns :ok" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [_] -> "x" end)
      assert :ok = DoubleDown.Testing.reset()
    end

    test "clears handlers so dispatch falls through to config" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [_] -> "test" end)
      assert "test" = Greeter.Port.greet("X")

      DoubleDown.Testing.reset()

      # No handler, no config → raises with test-oriented message
      assert_raise RuntimeError, ~r/No test handler set/, fn ->
        Greeter.Port.greet("X")
      end
    end

    test "clears log" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> name end)
      DoubleDown.Testing.enable_log(Greeter)
      Greeter.Port.greet("X")
      assert length(DoubleDown.Testing.get_log(Greeter)) == 1

      DoubleDown.Testing.reset()
      assert [] = DoubleDown.Testing.get_log(Greeter)
    end

    test "clears stateful handler state" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :increment, [n], s -> {s + n, s + n}
          _contract, :get_count, [], s -> {s, s}
        end,
        0
      )

      Counter.Port.increment(50)
      assert 50 = Counter.Port.get_count()

      DoubleDown.Testing.reset()

      # Re-register with fresh state
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :get_count, [], s -> {s, s}
        end,
        0
      )

      assert 0 = Counter.Port.get_count()
    end
  end

  # ── Dispatch logging ──────────────────────────────────────

  describe "enable_log/1" do
    test "returns :ok" do
      assert :ok = DoubleDown.Testing.enable_log(Greeter)
    end

    test "can be called before or after setting handler" do
      # Enable log first, then set handler
      DoubleDown.Testing.enable_log(Greeter)

      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "hi #{name}"
      end)

      Greeter.Port.greet("test")
      log = DoubleDown.Testing.get_log(Greeter)
      assert [{Greeter, :greet, ["test"], "hi test"}] = log
    end
  end

  describe "get_log/1" do
    test "returns empty list when logging not enabled" do
      assert [] = DoubleDown.Testing.get_log(Greeter)
    end

    test "returns empty list when logging enabled but no dispatches" do
      DoubleDown.Testing.enable_log(Greeter)
      assert [] = DoubleDown.Testing.get_log(Greeter)
    end

    test "returns entries in dispatch order" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, operation, args ->
        case {operation, args} do
          {:greet, [name]} -> "hi #{name}"
          {:fetch_greeting, [name]} -> {:ok, "hi #{name}"}
        end
      end)

      DoubleDown.Testing.enable_log(Greeter)

      Greeter.Port.greet("first")
      Greeter.Port.fetch_greeting("second")
      Greeter.Port.greet("third")

      log = DoubleDown.Testing.get_log(Greeter)
      assert length(log) == 3

      assert [
               {Greeter, :greet, ["first"], _},
               {Greeter, :fetch_greeting, ["second"], _},
               {Greeter, :greet, ["third"], _}
             ] = log
    end

    test "log entries include result" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "result: #{name}"
      end)

      DoubleDown.Testing.enable_log(Greeter)
      Greeter.Port.greet("check")

      [{_, _, _, result}] = DoubleDown.Testing.get_log(Greeter)
      assert result == "result: check"
    end

    test "logs are per-contract" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> n end)

      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn _contract, :increment, [n], s -> {s + n, s + n} end,
        0
      )

      DoubleDown.Testing.enable_log(Greeter)
      DoubleDown.Testing.enable_log(Counter)

      Greeter.Port.greet("a")
      Counter.Port.increment(1)
      Greeter.Port.greet("b")

      greeter_log = DoubleDown.Testing.get_log(Greeter)
      counter_log = DoubleDown.Testing.get_log(Counter)

      assert length(greeter_log) == 2
      assert length(counter_log) == 1
    end
  end

  # ── Async isolation ───────────────────────────────────────

  describe "async isolation" do
    test "handlers are isolated per process" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "parent: #{name}"
      end)

      parent_result = Greeter.Port.greet("test")
      assert parent_result == "parent: test"

      # An unrelated process (not Task.async which sets $callers) cannot dispatch
      test_pid = self()

      spawn(fn ->
        result =
          try do
            Greeter.Port.greet("child")
          rescue
            e -> {:error, e}
          end

        send(test_pid, {:child_result, result})
      end)

      assert_receive {:child_result, {:error, %RuntimeError{}}}, 1000
    end

    test "different processes can have different handlers for the same contract" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "process-1: #{name}"
      end)

      # Spawn a second process with a different handler
      test_pid = self()

      spawn(fn ->
        DoubleDown.Testing.set_stateless_handler(Greeter, fn
          _contract, :greet, [name] -> "process-2: #{name}"
        end)

        result = Greeter.Port.greet("test")
        send(test_pid, {:process_2_result, result})
      end)

      assert "process-1: test" = Greeter.Port.greet("test")

      assert_receive {:process_2_result, "process-2: test"}, 1000
    end

    test "logs are isolated per process" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> n end)
      DoubleDown.Testing.enable_log(Greeter)
      Greeter.Port.greet("parent")

      test_pid = self()

      spawn(fn ->
        DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> n end)
        DoubleDown.Testing.enable_log(Greeter)
        Greeter.Port.greet("child")
        send(test_pid, {:child_log, DoubleDown.Testing.get_log(Greeter)})
      end)

      parent_log = DoubleDown.Testing.get_log(Greeter)
      assert length(parent_log) == 1
      assert [{_, :greet, ["parent"], _}] = parent_log

      assert_receive {:child_log, child_log}, 1000
      assert length(child_log) == 1
      assert [{_, :greet, ["child"], _}] = child_log
    end
  end

  # ── Allow / process propagation ───────────────────────────

  describe "allow/3" do
    test "returns :ok for valid allow" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> n end)

      task = Task.async(fn -> receive do: (:go -> Greeter.Port.greet("x")) end)

      assert :ok = DoubleDown.Testing.allow(Greeter, self(), task.pid)

      send(task.pid, :go)
      assert "x" = Task.await(task)
    end

    test "allowed process shares handler with owner" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "shared: #{name}"
      end)

      task = Task.async(fn -> receive do: (:go -> Greeter.Port.greet("child")) end)
      DoubleDown.Testing.allow(Greeter, self(), task.pid)

      send(task.pid, :go)
      assert "shared: child" = Task.await(task)
    end

    test "allowed process shares stateful handler state" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :increment, [n], s -> {s + n, s + n}
          _contract, :get_count, [], s -> {s, s}
        end,
        0
      )

      Counter.Port.increment(10)

      task =
        Task.async(fn ->
          receive do
            :go -> Counter.Port.increment(5)
          end
        end)

      DoubleDown.Testing.allow(Counter, self(), task.pid)
      send(task.pid, :go)
      assert 15 = Task.await(task)

      # Parent sees the updated state
      assert 15 = Counter.Port.get_count()
    end

    test "allowed process logs are visible to owner" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> n end)
      DoubleDown.Testing.enable_log(Greeter)

      Greeter.Port.greet("parent")

      task =
        Task.async(fn ->
          receive do
            :go -> Greeter.Port.greet("child")
          end
        end)

      DoubleDown.Testing.allow(Greeter, self(), task.pid)
      send(task.pid, :go)
      Task.await(task)

      log = DoubleDown.Testing.get_log(Greeter)
      assert length(log) == 2
      operations = Enum.map(log, fn {_, _, args, _} -> args end)
      assert ["parent"] in operations
      assert ["child"] in operations
    end

    test "allow with lazy pid function" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> "lazy: #{n}" end)

      # Use a lazy function that returns the pid
      {:ok, agent} = Agent.start_link(fn -> nil end)

      DoubleDown.Testing.allow(Greeter, self(), fn -> agent end)

      # Agent should be able to dispatch through the handler via its GenServer process
      result =
        Agent.get(agent, fn _ ->
          Greeter.Port.greet("agent")
        end)

      assert "lazy: agent" = result

      Agent.stop(agent)
    end
  end

  # ── Multiple contracts in same test ───────────────────────

  describe "multiple contracts" do
    test "can register handlers for multiple contracts independently" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> "greet: #{n}" end)

      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn _contract, :get_count, [], s -> {s, s} end,
        99
      )

      assert "greet: X" = Greeter.Port.greet("X")
      assert 99 = Counter.Port.get_count()
    end

    test "resetting clears all contracts for the current process" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [_] -> "x" end)

      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn _contract, :get_count, [], s -> {s, s} end,
        0
      )

      DoubleDown.Testing.reset()

      assert_raise RuntimeError, ~r/No test handler set/, fn -> Greeter.Port.greet("X") end
      assert_raise RuntimeError, ~r/No test handler set/, fn -> Counter.Port.get_count() end
    end
  end
end

# Global mode tests must be async: false because they switch the
# ownership server to shared mode, which affects all processes.
defmodule DoubleDown.TestingGlobalModeTest do
  use ExUnit.Case, async: false

  alias DoubleDown.Test.Greeter
  alias DoubleDown.Test.Counter

  setup do
    on_exit(fn ->
      DoubleDown.Testing.set_mode_to_private()
      DoubleDown.Testing.reset()
    end)
  end

  describe "set_mode_to_global/0" do
    test "returns :ok" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [n] -> n end)
      assert :ok = DoubleDown.Testing.set_mode_to_global()
    end

    test "makes handlers accessible to spawned processes without allow" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> "global: #{name}" end)
      DoubleDown.Testing.set_mode_to_global()

      # Spawn a process that has no $callers link and no allow — only global mode makes this work
      task =
        Task.async(fn ->
          Greeter.Port.greet("from_task")
        end)

      assert "global: from_task" = Task.await(task)
    end

    test "makes handlers accessible to named GenServer processes" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> "global: #{name}" end)
      DoubleDown.Testing.set_mode_to_global()

      {:ok, agent} = Agent.start_link(fn -> nil end)

      result =
        Agent.get(agent, fn _ ->
          Greeter.Port.greet("from_agent")
        end)

      assert "global: from_agent" = result
      Agent.stop(agent)
    end

    test "works with stateful handlers" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :increment, [n], s -> {s + n, s + n}
          _contract, :get_count, [], s -> {s, s}
        end,
        0
      )

      DoubleDown.Testing.set_mode_to_global()

      # Increment from a spawned process
      task = Task.async(fn -> Counter.Port.increment(10) end)
      assert 10 = Task.await(task)

      # Parent sees the updated state
      assert 10 = Counter.Port.get_count()
    end

    test "handlers set after set_mode_to_global are also visible" do
      DoubleDown.Testing.set_mode_to_global()
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> "late: #{name}" end)

      task = Task.async(fn -> Greeter.Port.greet("after") end)
      assert "late: after" = Task.await(task)
    end
  end

  describe "set_mode_from_context/1" do
    test "sets global mode when async is false" do
      DoubleDown.Testing.set_mode_from_context(%{async: false})
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> "ctx: #{name}" end)

      # Bare spawn (no $callers) — only works in global mode
      task = Task.async(fn -> Greeter.Port.greet("from_task") end)
      assert "ctx: from_task" = Task.await(task)
    end

    test "sets private mode when async is true" do
      # First go global so we can prove it switches back
      DoubleDown.Testing.set_mode_to_global()
      DoubleDown.Testing.set_mode_from_context(%{async: true})
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> "priv: #{name}" end)

      # Bare spawn — should NOT see the handler in private mode
      ref = make_ref()
      parent = self()

      spawn(fn ->
        result =
          try do
            Greeter.Port.greet("should_fail")
          rescue
            e -> {:error, e}
          end

        send(parent, {ref, result})
      end)

      assert_receive {^ref, {:error, %RuntimeError{}}}
    end

    test "defaults to global mode when async key is absent" do
      DoubleDown.Testing.set_mode_from_context(%{})
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> "default: #{name}" end)

      task = Task.async(fn -> Greeter.Port.greet("from_task") end)
      assert "default: from_task" = Task.await(task)
    end
  end

  describe "set_mode_to_private/0" do
    test "restores per-process isolation after global mode" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, :greet, [name] -> "global: #{name}" end)
      DoubleDown.Testing.set_mode_to_global()

      # Global mode works — use bare spawn (no $callers) to prove it's global, not $callers
      ref = make_ref()
      parent = self()

      spawn(fn ->
        result = Greeter.Port.greet("check")
        send(parent, {ref, result})
      end)

      assert_receive {^ref, "global: check"}

      # Switch back to private
      DoubleDown.Testing.set_mode_to_private()

      # Now a bare spawned process can't see the handler
      ref2 = make_ref()

      spawn(fn ->
        result =
          try do
            Greeter.Port.greet("should_fail")
          rescue
            e -> {:error, e}
          end

        send(parent, {ref2, result})
      end)

      assert_receive {^ref2, {:error, %RuntimeError{}}}
    end
  end
end
