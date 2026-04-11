defmodule HexPort.HandlerTest do
  use ExUnit.Case, async: true

  alias HexPort.Handler
  alias HexPort.Test.Greeter
  alias HexPort.Test.Counter

  # ── expect tests ──────────────────────────────────────────

  describe "expect/3..4" do
    test "returns contract module for piping" do
      result = Handler.expect(Greeter, :greet, fn [_] -> "hi" end)
      assert result == Greeter
    end

    test "with times: n" do
      Greeter
      |> Handler.expect(:greet, fn [name] -> "hi #{name}" end, times: 3)

      assert "hi A" = Greeter.Port.greet("A")
      assert "hi B" = Greeter.Port.greet("B")
      assert "hi C" = Greeter.Port.greet("C")
    end

    test "times: 0 raises" do
      assert_raise ArgumentError, ~r/times must be >= 1/, fn ->
        Handler.expect(Greeter, :greet, fn [_] -> :ok end, times: 0)
      end
    end

    test "sequenced expectations consumed in order" do
      Greeter
      |> Handler.expect(:greet, fn [_] -> "first" end)
      |> Handler.expect(:greet, fn [_] -> "second" end)

      assert "first" = Greeter.Port.greet("A")
      assert "second" = Greeter.Port.greet("B")
    end

    test "multiple operations on same contract" do
      Greeter
      |> Handler.expect(:greet, fn [_] -> "hi" end)
      |> Handler.expect(:fetch_greeting, fn [_] -> {:ok, "hello"} end)

      assert "hi" = Greeter.Port.greet("A")
      assert {:ok, "hello"} = Greeter.Port.fetch_greeting("B")
    end

    test "multi-contract" do
      Handler.expect(Greeter, :greet, fn [name] -> "greet: #{name}" end)
      Handler.expect(Counter, :increment, fn [n] -> n * 10 end)

      assert "greet: Alice" = Greeter.Port.greet("Alice")
      assert 50 = Counter.Port.increment(5)
    end

    test "exhausted expects with no stub raises" do
      Handler.expect(Greeter, :greet, fn [_] -> "once" end)

      assert "once" = Greeter.Port.greet("A")

      assert_raise RuntimeError, ~r/Unexpected call to.*greet/, fn ->
        Greeter.Port.greet("B")
      end
    end
  end

  # ── stub tests ────────────────────────────────────────────

  describe "stub/2..3 per-operation" do
    test "returns contract module for piping" do
      result = Handler.stub(Greeter, :greet, fn [_] -> "hi" end)
      assert result == Greeter
    end

    test "stub called any number of times" do
      Handler.stub(Greeter, :greet, fn [name] -> "stub: #{name}" end)

      assert "stub: A" = Greeter.Port.greet("A")
      assert "stub: B" = Greeter.Port.greet("B")
      assert "stub: C" = Greeter.Port.greet("C")
    end

    test "stub called zero times is valid" do
      Handler.stub(Greeter, :greet, fn [_] -> "never called" end)

      assert :ok = Handler.verify!()
    end

    test "replacing stub overwrites previous" do
      Greeter
      |> Handler.stub(:greet, fn [_] -> "first" end)
      |> Handler.stub(:greet, fn [_] -> "second" end)

      assert "second" = Greeter.Port.greet("A")
    end

    test "expect and stub coexist — expects consumed first" do
      Greeter
      |> Handler.expect(:greet, fn [_] -> "expected" end)
      |> Handler.stub(:greet, fn [name] -> "stub: #{name}" end)

      assert "expected" = Greeter.Port.greet("A")
      assert "stub: B" = Greeter.Port.greet("B")
      assert "stub: C" = Greeter.Port.greet("C")
    end
  end

  describe "stub/2 function fallback" do
    test "returns contract module for piping" do
      result = Handler.stub(Greeter, fn _op, _args -> :fallback end)
      assert result == Greeter
    end

    test "handles operations without specific stubs" do
      Handler.stub(Greeter, fn
        :greet, [name] -> "fallback: #{name}"
        :fetch_greeting, [name] -> {:ok, "fallback: #{name}"}
      end)

      assert "fallback: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "fallback: Bob"} = Greeter.Port.fetch_greeting("Bob")
    end

    test "per-op stub takes priority over fallback" do
      Greeter
      |> Handler.stub(:greet, fn [name] -> "per-op: #{name}" end)
      |> Handler.stub(fn _op, [name] -> "fallback: #{name}" end)

      assert "per-op: Alice" = Greeter.Port.greet("Alice")
    end

    test "expects take priority over fallback" do
      Greeter
      |> Handler.stub(fn _op, [name] -> "fallback: #{name}" end)
      |> Handler.expect(:greet, fn [_] -> "expected" end)

      assert "expected" = Greeter.Port.greet("Alice")
      assert "fallback: Bob" = Greeter.Port.greet("Bob")
    end

    test "FunctionClauseError in fallback raises descriptive error" do
      Handler.stub(Greeter, fn
        :greet, [name] -> "only greet: #{name}"
      end)

      assert "only greet: Alice" = Greeter.Port.greet("Alice")

      assert_raise RuntimeError, ~r/Unexpected call to.*fetch_greeting/, fn ->
        Greeter.Port.fetch_greeting("Bob")
      end
    end

    test "reuses set_fn_handler-style functions" do
      handler_fn = fn
        :greet, [name] -> "handler: #{name}"
        :fetch_greeting, [name] -> {:ok, "handler: #{name}"}
      end

      Handler.stub(Greeter, handler_fn)

      assert "handler: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "handler: Bob"} = Greeter.Port.fetch_greeting("Bob")
    end
  end

  describe "stub/2 module fallback" do
    test "returns contract module for piping" do
      result = Handler.stub(Greeter, Greeter.Impl)
      assert result == Greeter
    end

    test "delegates to module" do
      Handler.stub(Greeter, Greeter.Impl)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end

    test "expects take priority" do
      Greeter
      |> Handler.stub(Greeter.Impl)
      |> Handler.expect(:greet, fn [_] -> "expected" end)

      assert "expected" = Greeter.Port.greet("Alice")
      assert "Hello, Bob!" = Greeter.Port.greet("Bob")
    end

    test "per-op stubs take priority" do
      Greeter
      |> Handler.stub(Greeter.Impl)
      |> Handler.stub(:greet, fn [name] -> "stubbed: #{name}" end)

      assert "stubbed: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end

    test "validates module at stub time — not loaded" do
      assert_raise ArgumentError, ~r/not loaded/, fn ->
        Handler.stub(Greeter, DoesNotExist.Module)
      end
    end

    test "validates module at stub time — missing functions" do
      assert_raise ArgumentError, ~r/missing functions/, fn ->
        Handler.stub(Greeter, String)
      end
    end
  end

  describe "stub/3 stateful fallback" do
    test "returns contract module for piping" do
      result =
        Handler.stub(Counter, fn _op, _args, state -> {:ok, state} end, 0)

      assert result == Counter
    end

    test "handles operations with state threading" do
      Handler.stub(
        Counter,
        fn
          :increment, [n], count -> {count + n, count + n}
          :get_count, [], count -> {count, count}
        end,
        0
      )

      assert 5 = Counter.Port.increment(5)
      assert 8 = Counter.Port.increment(3)
      assert 8 = Counter.Port.get_count()
    end

    test "expects take priority, fallback state unchanged on expect" do
      Counter
      |> Handler.stub(
        fn
          :increment, [n], count -> {count + n, count + n}
          :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Handler.expect(:increment, fn [_] -> 999 end)

      # First: expect fires, state unchanged (still 0)
      assert 999 = Counter.Port.increment(5)
      # Second: fallback, state is still 0
      assert 3 = Counter.Port.increment(3)
      assert 3 = Counter.Port.get_count()
    end

    test "error simulation — expect short-circuits before fallback" do
      Counter
      |> Handler.stub(
        fn
          :increment, [n], count -> {count + n, count + n}
          :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Handler.expect(:increment, fn [_n] -> {:error, :overflow} end)

      assert {:error, :overflow} = Counter.Port.increment(100)
      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end

    test "full priority chain: expects > per-op stubs > stateful fallback" do
      Counter
      |> Handler.stub(
        fn
          :increment, [n], count -> {count + n, count + n}
          :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Handler.expect(:increment, fn [_] -> :expected end)
      |> Handler.stub(:get_count, fn [] -> :stubbed end)

      assert :expected = Counter.Port.increment(5)
      assert :stubbed = Counter.Port.get_count()
      assert 3 = Counter.Port.increment(3)
    end

    test "FunctionClauseError in stateful fallback raises" do
      Handler.stub(
        Counter,
        fn :increment, [n], count -> {count + n, count + n} end,
        0
      )

      assert 5 = Counter.Port.increment(5)

      assert_raise RuntimeError, ~r/Unexpected call to.*get_count/, fn ->
        Counter.Port.get_count()
      end
    end
  end

  # ── fallback mutual exclusivity ───────────────────────────

  describe "fallback mutual exclusivity" do
    test "module replaces fn fallback" do
      Greeter
      |> Handler.stub(fn _op, _args -> :fn_fallback end)
      |> Handler.stub(Greeter.Impl)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
    end

    test "fn replaces module fallback" do
      Greeter
      |> Handler.stub(Greeter.Impl)
      |> Handler.stub(fn :greet, [name] -> "fn: #{name}" end)

      assert "fn: Alice" = Greeter.Port.greet("Alice")
    end
  end

  # ── dispatch with unexpected operations ───────────────────

  describe "unexpected operations" do
    test "raises with descriptive error" do
      Handler.stub(Greeter, :greet, fn [_] -> "hi" end)

      assert_raise RuntimeError, ~r/Unexpected call to.*fetch_greeting/, fn ->
        Greeter.Port.fetch_greeting("Alice")
      end
    end

    test "error message includes remaining expectations" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end)

      error =
        assert_raise RuntimeError, fn ->
          Greeter.Port.fetch_greeting("Alice")
        end

      assert error.message =~ "greet"
      assert error.message =~ "1 expected call(s) remaining"
    end
  end

  # ── :passthrough expects ──────────────────────────────────

  describe ":passthrough expects" do
    test "delegates to fn fallback" do
      Greeter
      |> Handler.stub(fn :greet, [name] -> "fallback: #{name}" end)
      |> Handler.expect(:greet, :passthrough)

      assert "fallback: Alice" = Greeter.Port.greet("Alice")
      assert :ok = Handler.verify!()
    end

    test "delegates to module fallback" do
      Greeter
      |> Handler.stub(Greeter.Impl)
      |> Handler.expect(:greet, :passthrough)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
      assert :ok = Handler.verify!()
    end

    test "delegates to stateful fallback with state threading" do
      Counter
      |> Handler.stub(
        fn
          :increment, [n], count -> {count + n, count + n}
          :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Handler.expect(:increment, :passthrough)
      |> Handler.expect(:increment, :passthrough)

      assert 5 = Counter.Port.increment(5)
      assert 8 = Counter.Port.increment(3)
      assert 8 = Counter.Port.get_count()
      assert :ok = Handler.verify!()
    end

    test "with times: n" do
      Greeter
      |> Handler.stub(Greeter.Impl)
      |> Handler.expect(:greet, :passthrough, times: 3)

      assert "Hello, A!" = Greeter.Port.greet("A")
      assert "Hello, B!" = Greeter.Port.greet("B")
      assert "Hello, C!" = Greeter.Port.greet("C")
      assert :ok = Handler.verify!()
    end

    test "consumed for verify! counting" do
      Counter
      |> Handler.stub(
        fn
          :increment, [n], count -> {count + n, count + n}
          :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Handler.expect(:increment, :passthrough, times: 2)

      Counter.Port.increment(1)

      assert_raise RuntimeError, ~r/expectations not fulfilled/, fn ->
        Handler.verify!()
      end
    end

    test "raises when no fallback configured" do
      Handler.expect(Greeter, :greet, :passthrough)

      assert_raise RuntimeError, ~r/Unexpected call to.*greet/, fn ->
        Greeter.Port.greet("Alice")
      end
    end

    test "mixed passthrough and function expects" do
      Greeter
      |> Handler.stub(Greeter.Impl)
      |> Handler.expect(:greet, :passthrough)
      |> Handler.expect(:greet, fn [_] -> "custom" end)
      |> Handler.expect(:greet, :passthrough)

      assert "Hello, A!" = Greeter.Port.greet("A")
      assert "custom" = Greeter.Port.greet("B")
      assert "Hello, C!" = Greeter.Port.greet("C")
      assert :ok = Handler.verify!()
    end
  end

  # ── verify! tests ─────────────────────────────────────────

  describe "verify!/0" do
    test "passes when all expects consumed" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end)

      Greeter.Port.greet("Alice")

      assert :ok = Handler.verify!()
    end

    test "raises when expects remain" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end, times: 2)

      Greeter.Port.greet("Alice")

      assert_raise RuntimeError, ~r/expectations not fulfilled/, fn ->
        Handler.verify!()
      end
    end

    test "error message lists contract, operation, and count" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end, times: 3)

      Greeter.Port.greet("Alice")

      error =
        assert_raise RuntimeError, fn ->
          Handler.verify!()
        end

      assert error.message =~ inspect(Greeter)
      assert error.message =~ "greet"
      assert error.message =~ "2 expected call(s) not made"
    end

    test "ignores stubs (zero calls OK)" do
      Handler.stub(Greeter, :greet, fn [_] -> "never" end)
      Handler.stub(Counter, :get_count, fn [] -> 0 end)

      assert :ok = Handler.verify!()
    end

    test "works across multiple contracts" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end)
      Handler.expect(Counter, :increment, fn [_] -> 1 end)

      Greeter.Port.greet("Alice")
      Counter.Port.increment(1)

      assert :ok = Handler.verify!()
    end

    test "reports unconsumed expects across multiple contracts" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end)
      Handler.expect(Counter, :increment, fn [_] -> 1 end)

      Greeter.Port.greet("Alice")

      error =
        assert_raise RuntimeError, fn ->
          Handler.verify!()
        end

      assert error.message =~ inspect(Counter)
      assert error.message =~ "increment"
    end

    test "raises when called with no handlers" do
      assert_raise RuntimeError, ~r/no handlers were installed/, fn ->
        Handler.verify!()
      end
    end
  end

  # ── verify!/1 (pid) tests ────────────────────────────────

  describe "verify!/1" do
    test "verifies expectations for a specific pid" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end)

      Greeter.Port.greet("Alice")

      assert :ok = Handler.verify!(self())
    end

    test "raises when expectations remain for the given pid" do
      Handler.expect(Greeter, :greet, fn [_] -> "hi" end, times: 2)

      Greeter.Port.greet("Alice")

      assert_raise RuntimeError, ~r/expectations not fulfilled/, fn ->
        Handler.verify!(self())
      end
    end
  end

  # ── verify_on_exit! tests ─────────────────────────────────

  describe "verify_on_exit!/0" do
    test "passes when all expectations consumed" do
      Handler.verify_on_exit!()

      Handler.expect(Greeter, :greet, fn [_] -> "hi" end)

      Greeter.Port.greet("Alice")
    end

    test "can be used as setup callback" do
      Handler.verify_on_exit!(%{})

      Handler.stub(Greeter, :greet, fn [name] -> "stub: #{name}" end)
    end
  end

  # ── integration tests ─────────────────────────────────────

  describe "full pipeline" do
    test "expect → stub → dispatch → verify" do
      Greeter
      |> Handler.expect(:greet, fn [name] -> "expected: #{name}" end)
      |> Handler.stub(:fetch_greeting, fn [name] -> {:ok, "stub: #{name}"} end)

      assert "expected: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "stub: Bob"} = Greeter.Port.fetch_greeting("Bob")
      assert {:ok, "stub: Carol"} = Greeter.Port.fetch_greeting("Carol")

      assert :ok = Handler.verify!()
    end

    test "sequenced expectations with different return values" do
      Greeter
      |> Handler.expect(:fetch_greeting, fn [_] -> {:error, :not_found} end)
      |> Handler.expect(:fetch_greeting, fn [name] -> {:ok, "Hello, #{name}!"} end)

      assert {:error, :not_found} = Greeter.Port.fetch_greeting("Alice")
      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")

      assert :ok = Handler.verify!()
    end

    test "times option with dispatch and verify" do
      Counter
      |> Handler.expect(:increment, fn [n] -> n end, times: 3)
      |> Handler.stub(:get_count, fn [] -> 0 end)

      Counter.Port.increment(1)
      Counter.Port.increment(2)
      Counter.Port.increment(3)
      Counter.Port.get_count()

      assert :ok = Handler.verify!()
    end

    test "mix of expects and stubs on same operation" do
      Greeter
      |> Handler.expect(:greet, fn [_] -> "first call" end)
      |> Handler.expect(:greet, fn [_] -> "second call" end)
      |> Handler.stub(:greet, fn [name] -> "stub: #{name}" end)

      assert "first call" = Greeter.Port.greet("A")
      assert "second call" = Greeter.Port.greet("B")
      assert "stub: C" = Greeter.Port.greet("C")
      assert "stub: D" = Greeter.Port.greet("D")

      assert :ok = Handler.verify!()
    end

    test "full priority chain with all layers" do
      Greeter
      |> Handler.stub(Greeter.Impl)
      |> Handler.stub(:fetch_greeting, fn [name] -> {:ok, "per-op: #{name}"} end)
      |> Handler.expect(:greet, fn [_] -> "expected" end)

      assert "expected" = Greeter.Port.greet("Alice")
      assert "Hello, Bob!" = Greeter.Port.greet("Bob")
      assert {:ok, "per-op: Carol"} = Greeter.Port.fetch_greeting("Carol")

      assert :ok = Handler.verify!()
    end
  end
end
