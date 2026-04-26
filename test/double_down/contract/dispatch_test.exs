defmodule DoubleDown.Contract.DispatchTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Test.Greeter
  alias DoubleDown.Test.Counter

  # -- Module handler dispatch --

  describe "module handler" do
    test "dispatches to a module implementing the behaviour" do
      DoubleDown.Testing.set_handler(Greeter, Greeter.Impl)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
    end

    test "dispatches fetch_greeting with ok tuple" do
      DoubleDown.Testing.set_handler(Greeter, Greeter.Impl)

      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end
  end

  # -- Fn handler dispatch --

  describe "fn handler" do
    test "dispatches to a function handler" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, operation, args ->
        case {operation, args} do
          {:greet, [name]} -> "Howdy, #{name}!"
          {:fetch_greeting, [name]} -> {:ok, "Howdy, #{name}!"}
        end
      end)

      assert "Howdy, Alice!" = Greeter.Port.greet("Alice")
      assert {:ok, "Howdy, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end
  end

  # -- Stateful handler dispatch --

  describe "stateful handler" do
    test "threads state across dispatches" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :increment, [amount], count -> {count + amount, count + amount}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )

      assert 5 = Counter.Port.increment(5)
      assert 8 = Counter.Port.increment(3)
      assert 8 = Counter.Port.get_count()
    end
  end

  # -- Config dispatch --

  describe "config dispatch" do
    test "dispatches to impl from Application config" do
      Application.put_env(:double_down, Greeter, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:double_down, Greeter) end)

      # No test handler set — should fall through to config
      assert "Hello, Charlie!" = Greeter.Port.greet("Charlie")
    end
  end

  # -- No handler raises --

  describe "no handler" do
    test "raises when no test handler and no config" do
      # Ensure no config
      Application.delete_env(:double_down, Greeter)

      assert_raise RuntimeError, ~r/No test handler set/, fn ->
        Greeter.Port.greet("Nobody")
      end
    end

    test "raises with test-oriented message mentioning set_stateless_handler" do
      Application.delete_env(:double_down, Greeter)

      assert_raise RuntimeError, ~r/set_stateless_handler/, fn ->
        Greeter.Port.greet("Nobody")
      end
    end

    test "raises when config exists but missing :impl key" do
      Application.put_env(:double_down, Greeter, [])
      on_exit(fn -> Application.delete_env(:double_down, Greeter) end)

      assert_raise RuntimeError, ~r/No test handler set/, fn ->
        Greeter.Port.greet("Nobody")
      end
    end
  end

  # -- Dispatch logging --

  describe "dispatch logging" do
    test "logs dispatches when logging is enabled" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn _contract, operation, args ->
        case {operation, args} do
          {:greet, [name]} -> "Hi, #{name}!"
          {:fetch_greeting, [name]} -> {:ok, "Hi, #{name}!"}
        end
      end)

      DoubleDown.Testing.enable_log(Greeter)

      Greeter.Port.greet("Alice")
      Greeter.Port.fetch_greeting("Bob")

      log = DoubleDown.Testing.get_log(Greeter)

      assert [
               {Greeter, :greet, ["Alice"], "Hi, Alice!"},
               {Greeter, :fetch_greeting, ["Bob"], {:ok, "Hi, Bob!"}}
             ] = log
    end

    test "returns empty log when logging not enabled" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "Hi, #{name}!"
      end)

      Greeter.Port.greet("Alice")

      assert [] = DoubleDown.Testing.get_log(Greeter)
    end

    test "logs stateful handler dispatches" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :increment, [amount], count -> {count + amount, count + amount}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )

      DoubleDown.Testing.enable_log(Counter)

      Counter.Port.increment(10)
      Counter.Port.get_count()

      log = DoubleDown.Testing.get_log(Counter)

      assert [
               {Counter, :increment, [10], 10},
               {Counter, :get_count, [], 10}
             ] = log
    end
  end

  # -- Key normalization --

  describe "key/3" do
    test "builds a canonical key" do
      assert {Greeter, :greet, ["Alice"]} =
               DoubleDown.Contract.Dispatch.key(Greeter, :greet, ["Alice"])
    end

    test "normalizes map argument order" do
      key1 = DoubleDown.Contract.Dispatch.key(Greeter, :greet, [%{b: 2, a: 1}])
      key2 = DoubleDown.Contract.Dispatch.key(Greeter, :greet, [%{a: 1, b: 2}])
      assert key1 == key2
    end

    test "normalizes keyword list order" do
      key1 = DoubleDown.Contract.Dispatch.key(Greeter, :greet, [[b: 2, a: 1]])
      key2 = DoubleDown.Contract.Dispatch.key(Greeter, :greet, [[a: 1, b: 2]])
      assert key1 == key2
    end
  end

  # -- Allow child processes --

  describe "allow/3" do
    test "allows a child Task to use the parent's handler" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "Hello from parent, #{name}!"
      end)

      task =
        Task.async(fn ->
          Greeter.Port.greet("Child")
        end)

      DoubleDown.Testing.allow(Greeter, self(), task.pid)

      assert "Hello from parent, Child!" = Task.await(task)
    end

    test "allowed child process can use stateful handler" do
      DoubleDown.Testing.set_stateful_handler(
        Counter,
        fn
          _contract, :increment, [amount], count -> {count + amount, count + amount}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )

      Counter.Port.increment(5)

      task =
        Task.async(fn ->
          Counter.Port.increment(3)
        end)

      DoubleDown.Testing.allow(Counter, self(), task.pid)

      assert 8 = Task.await(task)
      assert 8 = Counter.Port.get_count()
    end
  end

  # -- handler_active?/1 --

  describe "handler_active?/1" do
    test "returns false when no handler is installed" do
      refute DoubleDown.Contract.Dispatch.handler_active?(Greeter)
    end

    test "returns true after a fn handler is installed" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "Hi, #{name}!"
      end)

      assert DoubleDown.Contract.Dispatch.handler_active?(Greeter)
    end

    test "returns true after Double.fake/2 is called" do
      DoubleDown.Double.fake(Greeter, Greeter.Impl)

      assert DoubleDown.Contract.Dispatch.handler_active?(Greeter)
    end

    test "respects $callers chain — handler visible in spawned child" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "Hi, #{name}!"
      end)

      # Task.async sets $callers to [self()], so the child can see
      # the parent's handler via resolve_test_handler's callers walk.
      result =
        Task.async(fn ->
          DoubleDown.Contract.Dispatch.handler_active?(Greeter)
        end)
        |> Task.await()

      assert result == true
    end

    test "returns false for a different contract with no handler" do
      DoubleDown.Testing.set_stateless_handler(Greeter, fn
        _contract, :greet, [name] -> "Hi, #{name}!"
      end)

      # Greeter has a handler, but Counter does not
      assert DoubleDown.Contract.Dispatch.handler_active?(Greeter)
      refute DoubleDown.Contract.Dispatch.handler_active?(Counter)
    end
  end

  # -- get_state --

  describe "get_state" do
    test "returns nil when no handler installed" do
      assert DoubleDown.Contract.Dispatch.get_state(Greeter) == nil
    end

    test "returns state from current process" do
      DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)
      state = DoubleDown.Contract.Dispatch.get_state(DoubleDown.Repo)
      assert is_map(state)
    end

    test "returns state from child process via $callers chain" do
      DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)

      parent_state = DoubleDown.Contract.Dispatch.get_state(DoubleDown.Repo)

      child_state =
        Task.async(fn ->
          DoubleDown.Contract.Dispatch.get_state(DoubleDown.Repo)
        end)
        |> Task.await()

      assert child_state == parent_state
    end
  end
end
