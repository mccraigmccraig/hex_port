defmodule HexPort.DispatchTest do
  use ExUnit.Case, async: true

  alias HexPort.Test.Greeter
  alias HexPort.Test.Counter

  setup do
    on_exit(fn -> HexPort.Testing.reset() end)
    :ok
  end

  # -- Module handler dispatch --

  describe "module handler" do
    test "dispatches to a module implementing the behaviour" do
      HexPort.Testing.set_handler(Greeter, Greeter.Impl)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
    end

    test "dispatches fetch_greeting with ok tuple" do
      HexPort.Testing.set_handler(Greeter, Greeter.Impl)

      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end
  end

  # -- Fn handler dispatch --

  describe "fn handler" do
    test "dispatches to a function handler" do
      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "Howdy, #{name}!"
        :fetch_greeting, [name] -> {:ok, "Howdy, #{name}!"}
      end)

      assert "Howdy, Alice!" = Greeter.Port.greet("Alice")
      assert {:ok, "Howdy, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end
  end

  # -- Stateful handler dispatch --

  describe "stateful handler" do
    test "threads state across dispatches" do
      HexPort.Testing.set_stateful_handler(
        Counter,
        fn
          :increment, [amount], count -> {count + amount, count + amount}
          :get_count, [], count -> {count, count}
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
      Application.put_env(:hex_port, Greeter, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:hex_port, Greeter) end)

      # No test handler set — should fall through to config
      assert "Hello, Charlie!" = Greeter.Port.greet("Charlie")
    end
  end

  # -- No handler raises --

  describe "no handler" do
    test "raises when no test handler and no config" do
      # Ensure no config
      Application.delete_env(:hex_port, Greeter)

      assert_raise RuntimeError, ~r/No implementation configured/, fn ->
        Greeter.Port.greet("Nobody")
      end
    end

    test "raises when config exists but missing :impl key" do
      Application.put_env(:hex_port, Greeter, [])
      on_exit(fn -> Application.delete_env(:hex_port, Greeter) end)

      assert_raise RuntimeError, ~r/missing `:impl` key/, fn ->
        Greeter.Port.greet("Nobody")
      end
    end
  end

  # -- Dispatch logging --

  describe "dispatch logging" do
    test "logs dispatches when logging is enabled" do
      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "Hi, #{name}!"
        :fetch_greeting, [name] -> {:ok, "Hi, #{name}!"}
      end)

      HexPort.Testing.enable_log(Greeter)

      Greeter.Port.greet("Alice")
      Greeter.Port.fetch_greeting("Bob")

      log = HexPort.Testing.get_log(Greeter)

      assert [
               {Greeter, :greet, ["Alice"], "Hi, Alice!"},
               {Greeter, :fetch_greeting, ["Bob"], {:ok, "Hi, Bob!"}}
             ] = log
    end

    test "returns empty log when logging not enabled" do
      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "Hi, #{name}!"
      end)

      Greeter.Port.greet("Alice")

      assert [] = HexPort.Testing.get_log(Greeter)
    end

    test "logs stateful handler dispatches" do
      HexPort.Testing.set_stateful_handler(
        Counter,
        fn
          :increment, [amount], count -> {count + amount, count + amount}
          :get_count, [], count -> {count, count}
        end,
        0
      )

      HexPort.Testing.enable_log(Counter)

      Counter.Port.increment(10)
      Counter.Port.get_count()

      log = HexPort.Testing.get_log(Counter)

      assert [
               {Counter, :increment, [10], 10},
               {Counter, :get_count, [], 10}
             ] = log
    end
  end

  # -- Key normalization --

  describe "key/3" do
    test "builds a canonical key" do
      assert {Greeter, :greet, ["Alice"]} = HexPort.Dispatch.key(Greeter, :greet, ["Alice"])
    end

    test "normalizes map argument order" do
      key1 = HexPort.Dispatch.key(Greeter, :greet, [%{b: 2, a: 1}])
      key2 = HexPort.Dispatch.key(Greeter, :greet, [%{a: 1, b: 2}])
      assert key1 == key2
    end

    test "normalizes keyword list order" do
      key1 = HexPort.Dispatch.key(Greeter, :greet, [[b: 2, a: 1]])
      key2 = HexPort.Dispatch.key(Greeter, :greet, [[a: 1, b: 2]])
      assert key1 == key2
    end
  end

  # -- Allow child processes --

  describe "allow/3" do
    test "allows a child Task to use the parent's handler" do
      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "Hello from parent, #{name}!"
      end)

      task =
        Task.async(fn ->
          Greeter.Port.greet("Child")
        end)

      HexPort.Testing.allow(Greeter, self(), task.pid)

      assert "Hello from parent, Child!" = Task.await(task)
    end

    test "allowed child process can use stateful handler" do
      HexPort.Testing.set_stateful_handler(
        Counter,
        fn
          :increment, [amount], count -> {count + amount, count + amount}
          :get_count, [], count -> {count, count}
        end,
        0
      )

      Counter.Port.increment(5)

      task =
        Task.async(fn ->
          Counter.Port.increment(3)
        end)

      HexPort.Testing.allow(Counter, self(), task.pid)

      assert 8 = Task.await(task)
      assert 8 = Counter.Port.get_count()
    end
  end
end
