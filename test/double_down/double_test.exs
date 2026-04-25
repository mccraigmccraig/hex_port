defmodule DoubleDown.DoubleTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Double
  alias DoubleDown.Test.Greeter
  alias DoubleDown.Test.Counter

  # ── expect tests ──────────────────────────────────────────

  describe "expect/3..4" do
    test "returns contract module for piping" do
      result = Double.expect(Greeter, :greet, fn [_] -> "hi" end)
      assert result == Greeter
    end

    test "with times: n" do
      Greeter
      |> Double.expect(:greet, fn [name] -> "hi #{name}" end, times: 3)

      assert "hi A" = Greeter.Port.greet("A")
      assert "hi B" = Greeter.Port.greet("B")
      assert "hi C" = Greeter.Port.greet("C")
    end

    test "times: 0 raises" do
      assert_raise ArgumentError, ~r/times must be >= 1/, fn ->
        Double.expect(Greeter, :greet, fn [_] -> :ok end, times: 0)
      end
    end

    test "sequenced expectations consumed in order" do
      Greeter
      |> Double.expect(:greet, fn [_] -> "first" end)
      |> Double.expect(:greet, fn [_] -> "second" end)

      assert "first" = Greeter.Port.greet("A")
      assert "second" = Greeter.Port.greet("B")
    end

    test "multiple operations on same contract" do
      Greeter
      |> Double.expect(:greet, fn [_] -> "hi" end)
      |> Double.expect(:fetch_greeting, fn [_] -> {:ok, "hello"} end)

      assert "hi" = Greeter.Port.greet("A")
      assert {:ok, "hello"} = Greeter.Port.fetch_greeting("B")
    end

    test "multi-contract" do
      Double.expect(Greeter, :greet, fn [name] -> "greet: #{name}" end)
      Double.expect(Counter, :increment, fn [n] -> n * 10 end)

      assert "greet: Alice" = Greeter.Port.greet("Alice")
      assert 50 = Counter.Port.increment(5)
    end

    test "exhausted expects with no stub raises" do
      Double.expect(Greeter, :greet, fn [_] -> "once" end)

      assert "once" = Greeter.Port.greet("A")

      assert_raise RuntimeError, ~r/Unexpected call to.*greet/, fn ->
        Greeter.Port.greet("B")
      end
    end
  end

  # ── stub tests ────────────────────────────────────────────

  describe "stub/2..3 per-operation" do
    test "returns contract module for piping" do
      result = Double.stub(Greeter, :greet, fn [_] -> "hi" end)
      assert result == Greeter
    end

    test "stub called any number of times" do
      Double.stub(Greeter, :greet, fn [name] -> "stub: #{name}" end)

      assert "stub: A" = Greeter.Port.greet("A")
      assert "stub: B" = Greeter.Port.greet("B")
      assert "stub: C" = Greeter.Port.greet("C")
    end

    test "stub called zero times is valid" do
      Double.stub(Greeter, :greet, fn [_] -> "never called" end)

      assert :ok = Double.verify!()
    end

    test "replacing stub overwrites previous" do
      Greeter
      |> Double.stub(:greet, fn [_] -> "first" end)
      |> Double.stub(:greet, fn [_] -> "second" end)

      assert "second" = Greeter.Port.greet("A")
    end

    test "expect and stub coexist — expects consumed first" do
      Greeter
      |> Double.expect(:greet, fn [_] -> "expected" end)
      |> Double.stub(:greet, fn [name] -> "stub: #{name}" end)

      assert "expected" = Greeter.Port.greet("A")
      assert "stub: B" = Greeter.Port.greet("B")
      assert "stub: C" = Greeter.Port.greet("C")
    end

    test "stub can return passthrough() to delegate to fallback" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.stub(:increment, fn [n] ->
        if n > 100 do
          {:error, :overflow}
        else
          Double.passthrough()
        end
      end)

      # Normal increment — passthrough to fake
      assert 5 = Counter.Port.increment(5)
      # Overflow — stub handles it
      assert {:error, :overflow} = Counter.Port.increment(200)
      # State from first call preserved
      assert 5 = Counter.Port.get_count()
    end
  end

  # ── StubHandler module-based stub ──────────────────────────

  describe "StubHandler module-based stub" do
    alias DoubleDown.Repo
    alias DoubleDown.Test.Repo, as: TestRepo
    alias DoubleDown.Test.SimpleUser

    test "stub/2 with StubHandler module — writes only" do
      Double.stub(Repo, Repo.Stub)

      {:ok, user} = TestRepo.insert(SimpleUser.changeset(%{name: "Alice"}))
      assert %SimpleUser{name: "Alice"} = user
    end

    test "stub/2 with StubHandler — reads raise without fallback" do
      Double.stub(Repo, Repo.Stub)

      assert_raise ArgumentError, ~r/cannot service :all/, fn ->
        TestRepo.all(SimpleUser)
      end
    end

    test "stub/3 with StubHandler module and fallback_fn" do
      Double.stub(Repo, Repo.Stub, fn _contract, :all, [SimpleUser] ->
        [%SimpleUser{id: 1, name: "Alice"}]
      end)

      assert [%SimpleUser{name: "Alice"}] = TestRepo.all(SimpleUser)
    end

    test "stub/3 with StubHandler supports expects" do
      Repo
      |> Double.stub(Repo.Stub)
      |> Double.expect(:insert, fn [_changeset] -> {:error, :conflict} end)

      assert {:error, :conflict} = TestRepo.insert(SimpleUser.changeset(%{name: "Bob"}))

      assert {:ok, %SimpleUser{name: "Bob"}} =
               TestRepo.insert(SimpleUser.changeset(%{name: "Bob"}))
    end

    test "stub/2 with non-StubHandler module raises" do
      assert_raise ArgumentError, ~r/does not implement.*StubHandler/, fn ->
        Double.stub(Greeter, Greeter.Impl)
      end
    end

    test "returns contract module for piping" do
      result = Double.stub(Repo, Repo.Stub)
      assert result == Repo
    end

    test "per-operation stub/3 still works with operation atom" do
      Double.stub(Greeter, :greet, fn [name] -> "stub: #{name}" end)
      assert "stub: Alice" = Greeter.Port.greet("Alice")
    end
  end

  describe "stub/2 function fallback" do
    test "returns contract module for piping" do
      result = Double.stub(Greeter, fn _contract, _op, _args -> :fallback end)
      assert result == Greeter
    end

    test "handles operations without specific stubs" do
      Double.stub(Greeter, fn _contract, operation, args ->
        case {operation, args} do
          {:greet, [name]} -> "fallback: #{name}"
          {:fetch_greeting, [name]} -> {:ok, "fallback: #{name}"}
        end
      end)

      assert "fallback: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "fallback: Bob"} = Greeter.Port.fetch_greeting("Bob")
    end

    test "per-op stub takes priority over fallback" do
      Greeter
      |> Double.stub(:greet, fn [name] -> "per-op: #{name}" end)
      |> Double.stub(fn _contract, _op, [name] -> "fallback: #{name}" end)

      assert "per-op: Alice" = Greeter.Port.greet("Alice")
    end

    test "expects take priority over fallback" do
      Greeter
      |> Double.stub(fn _contract, _op, [name] -> "fallback: #{name}" end)
      |> Double.expect(:greet, fn [_] -> "expected" end)

      assert "expected" = Greeter.Port.greet("Alice")
      assert "fallback: Bob" = Greeter.Port.greet("Bob")
    end

    test "FunctionClauseError in fallback raises descriptive error" do
      Double.stub(Greeter, fn
        _contract, :greet, [name] -> "only greet: #{name}"
      end)

      assert "only greet: Alice" = Greeter.Port.greet("Alice")

      assert_raise RuntimeError, ~r/Unexpected call to.*fetch_greeting/, fn ->
        Greeter.Port.fetch_greeting("Bob")
      end
    end

    test "reuses set_fn_handler-style functions" do
      handler_fn = fn _contract, operation, args ->
        case {operation, args} do
          {:greet, [name]} -> "handler: #{name}"
          {:fetch_greeting, [name]} -> {:ok, "handler: #{name}"}
        end
      end

      Double.stub(Greeter, handler_fn)

      assert "handler: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "handler: Bob"} = Greeter.Port.fetch_greeting("Bob")
    end
  end

  describe "fake/2 module fake" do
    test "returns contract module for piping" do
      result = Double.fake(Greeter, Greeter.Impl)
      assert result == Greeter
    end

    test "delegates to module" do
      Double.fake(Greeter, Greeter.Impl)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end

    test "expects take priority" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.expect(:greet, fn [_] -> "expected" end)

      assert "expected" = Greeter.Port.greet("Alice")
      assert "Hello, Bob!" = Greeter.Port.greet("Bob")
    end

    test "per-op stubs take priority" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.stub(:greet, fn [name] -> "stubbed: #{name}" end)

      assert "stubbed: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")
    end

    test "module fake runs in the calling process, not the NimbleOwnership GenServer" do
      # This is critical for Ecto sandbox compatibility — the module's
      # functions must run in the test process (which has a sandbox checkout),
      # not in the NimbleOwnership GenServer process.
      test_pid = self()

      defmodule PidCapturingImpl do
        @behaviour DoubleDown.Test.Greeter

        @impl true
        def greet(_name), do: self()

        @impl true
        def fetch_greeting(_name), do: {:ok, self()}
      end

      Double.fake(Greeter, PidCapturingImpl)

      caller_pid = Greeter.Port.greet("Alice")
      assert caller_pid == test_pid
      refute caller_pid == GenServer.whereis(DoubleDown.Contract.Dispatch.Ownership)
    end

    test "validates module at stub time — not loaded" do
      assert_raise ArgumentError, ~r/not loaded/, fn ->
        Double.fake(Greeter, DoesNotExist.Module)
      end
    end

    test "validates module at stub time — missing functions" do
      assert_raise ArgumentError, ~r/missing functions/, fn ->
        Double.fake(Greeter, String)
      end
    end
  end

  describe "fake/3 stateful fake" do
    test "returns contract module for piping" do
      result =
        Double.fake(Counter, fn _contract, _op, _args, state -> {:ok, state} end, 0)

      assert result == Counter
    end

    test "handles operations with state threading" do
      Double.fake(
        Counter,
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )

      assert 5 = Counter.Port.increment(5)
      assert 8 = Counter.Port.increment(3)
      assert 8 = Counter.Port.get_count()
    end

    test "expects take priority, fallback state unchanged on expect" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_] -> 999 end)

      # First: expect fires, state unchanged (still 0)
      assert 999 = Counter.Port.increment(5)
      # Second: fallback, state is still 0
      assert 3 = Counter.Port.increment(3)
      assert 3 = Counter.Port.get_count()
    end

    test "error simulation — expect short-circuits before fallback" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_n] -> {:error, :overflow} end)

      assert {:error, :overflow} = Counter.Port.increment(100)
      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end

    test "full priority chain: expects > per-op stubs > stateful fallback" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_] -> :expected end)
      |> Double.stub(:get_count, fn [] -> :stubbed end)

      assert :expected = Counter.Port.increment(5)
      assert :stubbed = Counter.Port.get_count()
      assert 3 = Counter.Port.increment(3)
    end

    test "FunctionClauseError in stateful fallback raises" do
      Double.fake(
        Counter,
        fn _contract, :increment, [n], count -> {count + n, count + n} end,
        0
      )

      assert 5 = Counter.Port.increment(5)

      assert_raise RuntimeError, ~r/Unexpected call to.*get_count/, fn ->
        Counter.Port.get_count()
      end
    end

    test "stateful fallback returning bare value raises descriptive error" do
      Double.fake(
        Counter,
        fn _contract, :increment, [_n], _count -> 42 end,
        0
      )

      assert_raise ArgumentError, ~r/must return \{result, new_state\}/, fn ->
        Counter.Port.increment(5)
      end
    end
  end

  # ── fake/3 with 4-arity stateful fake ──────────────────────

  describe "fake/3 with 4-arity stateful fake (cross-contract state)" do
    test "5-arity stateful fake receives global state" do
      # Set up Greeter with a 4-arity stateful handler (another contract's state)
      Double.fake(
        Greeter,
        fn _contract, :greet, [name], state -> {"Hello #{name}", state} end,
        %{greeting_count: 0}
      )

      # Set up Counter with a 5-arity fake that reads Greeter's state
      Double.fake(
        Counter,
        fn _contract, :get_count, [], state, all_states ->
          greeter_state = Map.get(all_states, Greeter)
          {greeter_state, state}
        end,
        %{}
      )

      # The 4-arity fake can see Greeter's state
      result = Counter.Port.get_count()
      assert result == %{greeting_count: 0}
    end

    test "5-arity stateful fake with expects takes priority" do
      Double.fake(
        Counter,
        fn
          _contract, :increment, [n], count, _all_states -> {count + n, count + n}
          _contract, :get_count, [], count, _all_states -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_] -> 999 end)

      # Expect fires first, state unchanged
      assert 999 = Counter.Port.increment(5)
      # Fallback, state still 0
      assert 3 = Counter.Port.increment(3)
      assert 3 = Counter.Port.get_count()
    end

    test "4-arity fake still works when canonical handler is 5-arity" do
      # This verifies backward compatibility — the canonical handler is
      # always registered as 5-arity, but 4-arity fakes still work
      Double.fake(
        Counter,
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )

      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end

    test "passthrough with 5-arity fake threads state correctly" do
      Double.fake(
        Counter,
        fn
          _contract, :increment, [n], count, _all_states -> {count + n, count + n}
          _contract, :get_count, [], count, _all_states -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, :passthrough)

      # Passthrough delegates to 4-arity fake
      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end
  end

  # ── per-operation fakes ─────────────────────────────────────

  describe "per-operation fakes" do
    test "2-arity per-op fake receives and updates fallback state" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.fake(:increment, fn [n], count ->
        # Always double the increment
        {count + n * 2, count + n * 2}
      end)

      assert 10 = Counter.Port.increment(5)
      assert 16 = Counter.Port.increment(3)
      assert 16 = Counter.Port.get_count()
    end

    test "3-arity per-op fake receives all_states" do
      Greeter
      |> Double.fake(
        fn _contract, :greet, [name], state -> {"Hello #{name}", state} end,
        %{greeted: []}
      )

      Counter
      |> Double.fake(
        fn _contract, :get_count, [], count -> {count, count} end,
        0
      )
      |> Double.fake(:get_count, fn [], _state, all_states ->
        greeter_state = Map.get(all_states, Greeter)
        {greeter_state, 0}
      end)

      assert %{greeted: []} = Counter.Port.get_count()
    end

    test "per-op fake can return passthrough()" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.fake(:increment, fn [n], count ->
        if count + n > 100 do
          {{:error, :overflow}, count}
        else
          Double.passthrough()
        end
      end)

      assert 50 = Counter.Port.increment(50)
      assert 90 = Counter.Port.increment(40)
      # This would exceed 100 — per-op fake handles it
      assert {:error, :overflow} = Counter.Port.increment(20)
      assert 90 = Counter.Port.get_count()
    end

    test "replacing per-op fake overwrites previous" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.fake(:increment, fn [_n], count -> {:first, count} end)
      |> Double.fake(:increment, fn [_n], count -> {:second, count} end)

      assert :second = Counter.Port.increment(1)
    end

    test "raises at fake time if no stateful fallback" do
      Double.stub(Counter, :get_count, fn [] -> 0 end)

      assert_raise ArgumentError, ~r/no stateful fake is configured/, fn ->
        Double.fake(Counter, :increment, fn [_n], _state -> {0, 0} end)
      end
    end

    test "raises at dispatch time if per-op fake returns bare value" do
      Counter
      |> Double.fake(
        fn _contract, :increment, [n], count -> {count + n, count + n} end,
        0
      )
      |> Double.fake(:increment, fn [_n], _state -> 42 end)

      assert_raise ArgumentError, ~r/must return \{result, new_state\}/, fn ->
        Counter.Port.increment(5)
      end
    end

    test "expects take priority over per-op fakes" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.fake(:increment, fn [_n], count -> {:from_op_fake, count} end)
      |> Double.expect(:increment, fn [_] -> :from_expect end)

      # First call: expect wins
      assert :from_expect = Counter.Port.increment(1)
      # Second call: expect consumed, per-op fake handles
      assert :from_op_fake = Counter.Port.increment(1)
    end

    test "per-op fakes take priority over per-op stubs" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.stub(:increment, fn [_] -> :from_stub end)
      |> Double.fake(:increment, fn [_n], count -> {:from_op_fake, count} end)

      assert :from_op_fake = Counter.Port.increment(1)
    end
  end

  # ── FakeHandler module-based fake ──────────────────────────

  describe "FakeHandler module-based fake" do
    alias DoubleDown.Repo
    alias DoubleDown.Test.Repo, as: TestRepo
    alias DoubleDown.Test.SimpleUser

    test "fake/2 with FakeHandler module uses default state" do
      Double.fake(Repo, Repo.OpenInMemory)

      {:ok, user} = TestRepo.insert(SimpleUser.changeset(%{name: "Alice"}))
      assert %SimpleUser{name: "Alice"} = TestRepo.get(SimpleUser, user.id)
    end

    test "fake/3 with FakeHandler module passes seed as list" do
      alice = %SimpleUser{id: 1, name: "Alice"}
      Double.fake(Repo, Repo.OpenInMemory, [alice])

      assert %SimpleUser{name: "Alice"} = TestRepo.get(SimpleUser, 1)
    end

    test "fake/3 with FakeHandler module passes seed as map" do
      alice = %SimpleUser{id: 1, name: "Alice"}
      Double.fake(Repo, Repo.OpenInMemory, %{SimpleUser => %{1 => alice}})

      assert %SimpleUser{name: "Alice"} = TestRepo.get(SimpleUser, 1)
    end

    test "fake/4 passes seed and opts to new/2" do
      alice = %SimpleUser{id: 1, name: "Alice"}

      Double.fake(Repo, Repo.OpenInMemory, [alice],
        fallback_fn: fn _contract, :all, [SimpleUser], state ->
          state |> Map.get(SimpleUser, %{}) |> Map.values()
        end
      )

      assert %SimpleUser{name: "Alice"} = TestRepo.get(SimpleUser, 1)
      assert [%SimpleUser{name: "Alice"}] = TestRepo.all(SimpleUser)
    end

    test "FakeHandler fake supports expects" do
      Double.fake(Repo, Repo.OpenInMemory)
      |> Double.expect(:insert, fn [_changeset] ->
        {:error, :conflict}
      end)

      assert {:error, :conflict} = TestRepo.insert(SimpleUser.changeset(%{name: "Bob"}))

      # Second insert goes through InMemory
      assert {:ok, %SimpleUser{name: "Bob"}} =
               TestRepo.insert(SimpleUser.changeset(%{name: "Bob"}))
    end

    test "fake/2 with non-FakeHandler module uses module fake" do
      # Greeter.Impl doesn't implement FakeHandler — should be module fake
      Double.fake(Greeter, Greeter.Impl)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
    end

    test "raises for fake/3 with non-FakeHandler module" do
      assert_raise ArgumentError, ~r/does not implement.*FakeHandler/, fn ->
        Double.fake(Greeter, Greeter.Impl, %{})
      end
    end

    test "returns contract module for piping" do
      result = Double.fake(Repo, Repo.OpenInMemory)
      assert result == Repo
    end
  end

  # ── fallback mutual exclusivity ───────────────────────────

  describe "fallback mutual exclusivity" do
    test "module replaces fn fallback" do
      Greeter
      |> Double.stub(fn _contract, _op, _args -> :fn_fallback end)
      |> Double.fake(Greeter.Impl)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
    end

    test "fn replaces module fallback" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.stub(fn _contract, :greet, [name] -> "fn: #{name}" end)

      assert "fn: Alice" = Greeter.Port.greet("Alice")
    end
  end

  # ── stateful expect responders ──────────────────────────────

  describe "stateful expect responders" do
    test "2-arity expect receives and updates fallback state" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [n], count ->
        # Double the increment and update state
        {count + n * 2, count + n * 2}
      end)

      # First call: 2-arity expect fires, state becomes 10
      assert 10 = Counter.Port.increment(5)
      # Second call: fallback, state is 10, becomes 13
      assert 13 = Counter.Port.increment(3)
      assert 13 = Counter.Port.get_count()
    end

    test "3-arity expect receives fallback state and all_states" do
      Greeter
      |> Double.fake(
        fn _contract, :greet, [name], state -> {"Hello #{name}", state} end,
        %{greeted: []}
      )

      Counter
      |> Double.fake(
        fn
          _contract, :increment, [_n], count -> {count, count}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:get_count, fn [], _state, all_states ->
        greeter_state = Map.get(all_states, Greeter)
        {greeter_state, 0}
      end)

      result = Counter.Port.get_count()
      assert result == %{greeted: []}
    end

    test "stateful expects thread state through sequenced calls" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [n], count ->
        {count + n, count + n}
      end)
      |> Double.expect(:increment, fn [n], count ->
        # Second expect sees state updated by first expect
        {count + n * 10, count + n * 10}
      end)

      assert 5 = Counter.Port.increment(5)
      # State is now 5, second expect multiplies by 10
      assert 35 = Counter.Port.increment(3)
      assert 35 = Counter.Port.get_count()
    end

    test "raises at expect time if no stateful fake configured — 2-arity" do
      Double.stub(Counter, :get_count, fn [] -> 0 end)

      assert_raise ArgumentError, ~r/no stateful fake is configured/, fn ->
        Double.expect(Counter, :increment, fn [_n], _state ->
          {0, 0}
        end)
      end
    end

    test "raises at expect time if no stateful fake configured — 3-arity" do
      Double.stub(Counter, :get_count, fn [] -> 0 end)

      assert_raise ArgumentError, ~r/no stateful fake is configured/, fn ->
        Double.expect(Counter, :increment, fn [_n], _state, _all ->
          {0, 0}
        end)
      end
    end

    test "raises at dispatch time if 2-arity responder returns bare value" do
      Counter
      |> Double.fake(
        fn _contract, :increment, [n], count -> {count + n, count + n} end,
        0
      )
      |> Double.expect(:increment, fn [_n], _state ->
        # Wrong — bare result instead of {result, new_state}
        42
      end)

      assert_raise ArgumentError, ~r/must return \{result, new_state\}/, fn ->
        Counter.Port.increment(5)
      end
    end

    test "raises at dispatch time if 3-arity responder returns bare value" do
      Counter
      |> Double.fake(
        fn _contract, :increment, [n], count -> {count + n, count + n} end,
        0
      )
      |> Double.expect(:increment, fn [_n], _state, _all ->
        42
      end)

      assert_raise ArgumentError, ~r/must return \{result, new_state\}/, fn ->
        Counter.Port.increment(5)
      end
    end

    test "1-arity expects still work unchanged with stateful fake" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_n] -> 999 end)

      # 1-arity: state unchanged
      assert 999 = Counter.Port.increment(5)
      assert 3 = Counter.Port.increment(3)
      assert 3 = Counter.Port.get_count()
    end
  end

  # ── Double.passthrough() from expect responders ────────────

  describe "Double.passthrough() from expect responders" do
    test "1-arity responder returning passthrough() delegates to stateful fake" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_n] ->
        Double.passthrough()
      end)

      # Passthrough to fake — increments normally
      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end

    test "2-arity responder returning passthrough() delegates, state unchanged" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_n], _state ->
        Double.passthrough()
      end)

      # Passthrough to fake — state managed by fake, not the expect
      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end

    test "3-arity responder returning passthrough() delegates, state unchanged" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_n], _state, _all_states ->
        Double.passthrough()
      end)

      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end

    test "conditional passthrough — handle or delegate based on state" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_n], count ->
        if count >= 10 do
          # Over threshold — return error
          {{:error, :overflow}, count}
        else
          # Under threshold — let fake handle it
          Double.passthrough()
        end
      end)

      # First call: count is 0, passthrough to fake, count becomes 5
      assert 5 = Counter.Port.increment(5)
      assert 5 = Counter.Port.get_count()
    end

    test "passthrough() expect is consumed for verify! counting" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, fn [_n] ->
        Double.passthrough()
      end)

      assert 5 = Counter.Port.increment(5)

      # verify! succeeds — the expect was consumed
      Double.verify!()
    end

    test "passthrough() works with module fake" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.expect(:greet, fn [_name] ->
        Double.passthrough()
      end)

      # Delegates to Greeter.Impl
      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
    end

    test "passthrough() works with fn fallback" do
      Greeter
      |> Double.stub(fn _contract, :greet, [name] -> "stub: #{name}" end)
      |> Double.expect(:greet, fn [_name] ->
        Double.passthrough()
      end)

      assert "stub: Alice" = Greeter.Port.greet("Alice")
    end
  end

  # ── dispatch with unexpected operations ───────────────────

  describe "unexpected operations" do
    test "raises with descriptive error" do
      Double.stub(Greeter, :greet, fn [_] -> "hi" end)

      assert_raise RuntimeError, ~r/Unexpected call to.*fetch_greeting/, fn ->
        Greeter.Port.fetch_greeting("Alice")
      end
    end

    test "error message includes remaining expectations" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end)

      error =
        assert_raise RuntimeError, fn ->
          Greeter.Port.fetch_greeting("Alice")
        end

      assert error.message =~ "greet"
      assert error.message =~ "1 expected call(s) remaining"
    end
  end

  # ── Double/Testing API mixing guard ────────────────────────

  describe "mixing Double and Testing APIs" do
    test "raises if Double.expect is called on a contract with a raw Testing handler" do
      DoubleDown.Testing.set_fn_handler(Greeter, fn _contract, :greet, [name] -> name end)

      assert_raise ArgumentError, ~r/Cannot use Double API/, fn ->
        Double.expect(Greeter, :greet, fn [_] -> "hi" end)
      end
    end

    test "raises if Double.stub is called on a contract with a raw Testing handler" do
      DoubleDown.Testing.set_fn_handler(Greeter, fn _contract, :greet, [name] -> name end)

      assert_raise ArgumentError, ~r/Cannot use Double API/, fn ->
        Double.stub(Greeter, :greet, fn [_] -> "hi" end)
      end
    end

    test "raises if Double.fake is called on a contract with a raw Testing handler" do
      DoubleDown.Testing.set_stateful_handler(
        Greeter,
        fn _contract, :greet, [name], state -> {name, state} end,
        %{}
      )

      assert_raise ArgumentError, ~r/Cannot use Double API/, fn ->
        Double.fake(Greeter, fn _contract, :greet, [name], state -> {name, state} end, %{})
      end
    end

    test "raises if Testing.set_fn_handler is called on a contract with a Double handler" do
      Double.stub(Greeter, :greet, fn [name] -> name end)

      assert_raise ArgumentError, ~r/A handler is already installed/, fn ->
        DoubleDown.Testing.set_fn_handler(Greeter, fn _contract, :greet, [name] -> name end)
      end
    end

    test "raises if Testing.set_handler is called on a contract with a Double handler" do
      Double.stub(Greeter, :greet, fn [name] -> name end)

      assert_raise ArgumentError, ~r/A handler is already installed/, fn ->
        DoubleDown.Testing.set_handler(Greeter, Greeter.Impl)
      end
    end

    test "raises if Testing.set_stateful_handler is called on a contract with a Double handler" do
      Double.stub(Greeter, :greet, fn [name] -> name end)

      assert_raise ArgumentError, ~r/A handler is already installed/, fn ->
        DoubleDown.Testing.set_stateful_handler(
          Greeter,
          fn _contract, :greet, [name], state -> {name, state} end,
          %{}
        )
      end
    end
  end

  # ── :passthrough expects ──────────────────────────────────

  describe ":passthrough expects" do
    test "delegates to fn fallback" do
      Greeter
      |> Double.stub(fn _contract, :greet, [name] -> "fallback: #{name}" end)
      |> Double.expect(:greet, :passthrough)

      assert "fallback: Alice" = Greeter.Port.greet("Alice")
      assert :ok = Double.verify!()
    end

    test "delegates to module fallback" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.expect(:greet, :passthrough)

      assert "Hello, Alice!" = Greeter.Port.greet("Alice")
      assert :ok = Double.verify!()
    end

    test "delegates to stateful fallback with state threading" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, :passthrough)
      |> Double.expect(:increment, :passthrough)

      assert 5 = Counter.Port.increment(5)
      assert 8 = Counter.Port.increment(3)
      assert 8 = Counter.Port.get_count()
      assert :ok = Double.verify!()
    end

    test "with times: n" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.expect(:greet, :passthrough, times: 3)

      assert "Hello, A!" = Greeter.Port.greet("A")
      assert "Hello, B!" = Greeter.Port.greet("B")
      assert "Hello, C!" = Greeter.Port.greet("C")
      assert :ok = Double.verify!()
    end

    test "consumed for verify! counting" do
      Counter
      |> Double.fake(
        fn
          _contract, :increment, [n], count -> {count + n, count + n}
          _contract, :get_count, [], count -> {count, count}
        end,
        0
      )
      |> Double.expect(:increment, :passthrough, times: 2)

      Counter.Port.increment(1)

      assert_raise RuntimeError, ~r/expectations not fulfilled/, fn ->
        Double.verify!()
      end
    end

    test "raises when no fallback configured" do
      Double.expect(Greeter, :greet, :passthrough)

      assert_raise RuntimeError, ~r/Unexpected call to.*greet/, fn ->
        Greeter.Port.greet("Alice")
      end
    end

    test "mixed passthrough and function expects" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.expect(:greet, :passthrough)
      |> Double.expect(:greet, fn [_] -> "custom" end)
      |> Double.expect(:greet, :passthrough)

      assert "Hello, A!" = Greeter.Port.greet("A")
      assert "custom" = Greeter.Port.greet("B")
      assert "Hello, C!" = Greeter.Port.greet("C")
      assert :ok = Double.verify!()
    end
  end

  # ── verify! tests ─────────────────────────────────────────

  describe "verify!/0" do
    test "passes when all expects consumed" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end)

      Greeter.Port.greet("Alice")

      assert :ok = Double.verify!()
    end

    test "raises when expects remain" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end, times: 2)

      Greeter.Port.greet("Alice")

      assert_raise RuntimeError, ~r/expectations not fulfilled/, fn ->
        Double.verify!()
      end
    end

    test "error message lists contract, operation, and count" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end, times: 3)

      Greeter.Port.greet("Alice")

      error =
        assert_raise RuntimeError, fn ->
          Double.verify!()
        end

      assert error.message =~ inspect(Greeter)
      assert error.message =~ "greet"
      assert error.message =~ "2 expected call(s) not made"
    end

    test "ignores stubs (zero calls OK)" do
      Double.stub(Greeter, :greet, fn [_] -> "never" end)
      Double.stub(Counter, :get_count, fn [] -> 0 end)

      assert :ok = Double.verify!()
    end

    test "works across multiple contracts" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end)
      Double.expect(Counter, :increment, fn [_] -> 1 end)

      Greeter.Port.greet("Alice")
      Counter.Port.increment(1)

      assert :ok = Double.verify!()
    end

    test "reports unconsumed expects across multiple contracts" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end)
      Double.expect(Counter, :increment, fn [_] -> 1 end)

      Greeter.Port.greet("Alice")

      error =
        assert_raise RuntimeError, fn ->
          Double.verify!()
        end

      assert error.message =~ inspect(Counter)
      assert error.message =~ "increment"
    end

    test "returns :ok when called with no handlers" do
      assert :ok = Double.verify!()
    end
  end

  # ── verify!/1 (pid) tests ────────────────────────────────

  describe "verify!/1" do
    test "verifies expectations for a specific pid" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end)

      Greeter.Port.greet("Alice")

      assert :ok = Double.verify!(self())
    end

    test "raises when expectations remain for the given pid" do
      Double.expect(Greeter, :greet, fn [_] -> "hi" end, times: 2)

      Greeter.Port.greet("Alice")

      assert_raise RuntimeError, ~r/expectations not fulfilled/, fn ->
        Double.verify!(self())
      end
    end
  end

  # ── verify_on_exit! tests ─────────────────────────────────

  describe "verify_on_exit!/0" do
    test "passes when all expectations consumed" do
      Double.verify_on_exit!()

      Double.expect(Greeter, :greet, fn [_] -> "hi" end)

      Greeter.Port.greet("Alice")
    end

    test "can be used as setup callback" do
      Double.verify_on_exit!(%{})

      Double.stub(Greeter, :greet, fn [name] -> "stub: #{name}" end)
    end
  end

  # ── integration tests ─────────────────────────────────────

  describe "full pipeline" do
    test "expect → stub → dispatch → verify" do
      Greeter
      |> Double.expect(:greet, fn [name] -> "expected: #{name}" end)
      |> Double.stub(:fetch_greeting, fn [name] -> {:ok, "stub: #{name}"} end)

      assert "expected: Alice" = Greeter.Port.greet("Alice")
      assert {:ok, "stub: Bob"} = Greeter.Port.fetch_greeting("Bob")
      assert {:ok, "stub: Carol"} = Greeter.Port.fetch_greeting("Carol")

      assert :ok = Double.verify!()
    end

    test "sequenced expectations with different return values" do
      Greeter
      |> Double.expect(:fetch_greeting, fn [_] -> {:error, :not_found} end)
      |> Double.expect(:fetch_greeting, fn [name] -> {:ok, "Hello, #{name}!"} end)

      assert {:error, :not_found} = Greeter.Port.fetch_greeting("Alice")
      assert {:ok, "Hello, Bob!"} = Greeter.Port.fetch_greeting("Bob")

      assert :ok = Double.verify!()
    end

    test "times option with dispatch and verify" do
      Counter
      |> Double.expect(:increment, fn [n] -> n end, times: 3)
      |> Double.stub(:get_count, fn [] -> 0 end)

      Counter.Port.increment(1)
      Counter.Port.increment(2)
      Counter.Port.increment(3)
      Counter.Port.get_count()

      assert :ok = Double.verify!()
    end

    test "mix of expects and stubs on same operation" do
      Greeter
      |> Double.expect(:greet, fn [_] -> "first call" end)
      |> Double.expect(:greet, fn [_] -> "second call" end)
      |> Double.stub(:greet, fn [name] -> "stub: #{name}" end)

      assert "first call" = Greeter.Port.greet("A")
      assert "second call" = Greeter.Port.greet("B")
      assert "stub: C" = Greeter.Port.greet("C")
      assert "stub: D" = Greeter.Port.greet("D")

      assert :ok = Double.verify!()
    end

    test "full priority chain with all layers" do
      Greeter
      |> Double.fake(Greeter.Impl)
      |> Double.stub(:fetch_greeting, fn [name] -> {:ok, "per-op: #{name}"} end)
      |> Double.expect(:greet, fn [_] -> "expected" end)

      assert "expected" = Greeter.Port.greet("Alice")
      assert "Hello, Bob!" = Greeter.Port.greet("Bob")
      assert {:ok, "per-op: Carol"} = Greeter.Port.fetch_greeting("Carol")

      assert :ok = Double.verify!()
    end
  end
end
