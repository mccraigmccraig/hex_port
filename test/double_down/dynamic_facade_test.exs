defmodule DoubleDown.DynamicFacadeTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Double
  alias DoubleDown.Test.DynamicTarget

  # DynamicTarget is set up in test_helper.exs via Dynamic.setup/1.
  # Original functions: greet/1, add/2, zero_arity/0

  describe "Dynamic.setup?/1" do
    test "returns true for set up modules" do
      assert DoubleDown.DynamicFacade.setup?(DynamicTarget)
    end

    test "returns false for non-set-up modules" do
      refute DoubleDown.DynamicFacade.setup?(String)
    end
  end

  describe "dispatch without handler — falls through to original" do
    test "original functions work when no handler installed" do
      assert "Original: Alice" = DynamicTarget.greet("Alice")
      assert 5 = DynamicTarget.add(2, 3)
      assert :original = DynamicTarget.zero_arity()
    end
  end

  describe "dispatch with Double.stub" do
    test "fn stub overrides all operations" do
      Double.stub(DynamicTarget, fn
        :greet, [name] -> "Stubbed: #{name}"
        :add, [a, b] -> a * b
        :zero_arity, [] -> :stubbed
      end)

      assert "Stubbed: Alice" = DynamicTarget.greet("Alice")
      assert 6 = DynamicTarget.add(2, 3)
      assert :stubbed = DynamicTarget.zero_arity()
    end
  end

  describe "dispatch with Double.expect" do
    test "expects are consumed in order" do
      Double.stub(DynamicTarget, fn :greet, [name] -> "Stub: #{name}" end)

      Double.expect(DynamicTarget, :greet, fn [_] -> "First" end)
      Double.expect(DynamicTarget, :greet, fn [_] -> "Second" end)

      assert "First" = DynamicTarget.greet("Alice")
      assert "Second" = DynamicTarget.greet("Bob")
      assert "Stub: Carol" = DynamicTarget.greet("Carol")

      Double.verify!()
    end
  end

  describe "dispatch with Double.fake (stateful)" do
    test "stateful fake handles operations" do
      Double.fake(
        DynamicTarget,
        fn
          :greet, [name], state ->
            count = Map.get(state, :greet_count, 0) + 1
            {"Hello #{name} (#{count})", Map.put(state, :greet_count, count)}

          :add, [a, b], state ->
            {a + b, state}

          :zero_arity, [], state ->
            {:fake, state}
        end,
        %{}
      )

      assert "Hello Alice (1)" = DynamicTarget.greet("Alice")
      assert "Hello Bob (2)" = DynamicTarget.greet("Bob")
      assert 5 = DynamicTarget.add(2, 3)
      assert :fake = DynamicTarget.zero_arity()
    end

    test "expects layer over stateful fake" do
      Double.fake(
        DynamicTarget,
        fn
          :greet, [name], state -> {"Fake: #{name}", state}
          :add, [a, b], state -> {a + b, state}
        end,
        %{}
      )

      Double.expect(DynamicTarget, :greet, fn [_] -> "Expected" end)

      # Expect fires first
      assert "Expected" = DynamicTarget.greet("Alice")
      # Falls through to fake
      assert "Fake: Bob" = DynamicTarget.greet("Bob")

      Double.verify!()
    end
  end

  describe "Double.dynamic/1" do
    test "delegates to original, allows expects on top" do
      DynamicTarget
      |> Double.dynamic()
      |> Double.expect(:greet, fn [_] -> "Overridden" end)

      assert "Overridden" = DynamicTarget.greet("Alice")
      # add falls through to the original via module fake
      assert 5 = DynamicTarget.add(2, 3)
      # second greet falls through to original
      assert "Original: Bob" = DynamicTarget.greet("Bob")

      Double.verify!()
    end

    test "raises for modules not set up with Dynamic.setup" do
      assert_raise ArgumentError, ~r/has not been set up/, fn ->
        Double.dynamic(String)
      end
    end
  end

  describe "dispatch logging" do
    test "logs dispatched calls" do
      Double.stub(DynamicTarget, fn
        :greet, [name] -> "Logged: #{name}"
      end)

      DoubleDown.Testing.enable_log(DynamicTarget)

      DynamicTarget.greet("Alice")

      log = DoubleDown.Testing.get_log(DynamicTarget)
      assert [{DynamicTarget, :greet, ["Alice"], "Logged: Alice"}] = log
    end
  end

  describe "passthrough expects" do
    test ":passthrough expect delegates to original" do
      Double.fake(
        DynamicTarget,
        fn :greet, [name], state -> {"Fake: #{name}", state} end,
        %{}
      )
      |> Double.expect(:greet, :passthrough)

      # Passthrough delegates to the fake (which is the fallback)
      assert "Fake: Alice" = DynamicTarget.greet("Alice")
      # Second call goes to fake directly
      assert "Fake: Bob" = DynamicTarget.greet("Bob")

      Double.verify!()
    end

    test "Double.passthrough() from stateful responder delegates to fake" do
      Double.fake(
        DynamicTarget,
        fn :greet, [name], state -> {"Fake: #{name}", state} end,
        %{}
      )
      |> Double.expect(:greet, fn [name], _state ->
        if name == "special" do
          {"Special!", %{}}
        else
          Double.passthrough()
        end
      end)

      # "special" is handled by the expect
      assert "Special!" = DynamicTarget.greet("special")
      # "Alice" passes through to the fake
      assert "Fake: Alice" = DynamicTarget.greet("Alice")
    end
  end

  describe "stateful expect responders with dynamic facade" do
    test "2-arity expect reads and updates fake state" do
      Double.fake(
        DynamicTarget,
        fn
          :greet, [name], state -> {"Fake: #{name}", state}
          :zero_arity, [], state -> {state[:count] || 0, state}
        end,
        %{count: 0}
      )
      |> Double.expect(:greet, fn [name], state ->
        count = (state[:count] || 0) + 1
        {"Counted(#{count}): #{name}", %{state | count: count}}
      end)

      assert "Counted(1): Alice" = DynamicTarget.greet("Alice")
      # State was updated — verify via zero_arity
      assert 1 = DynamicTarget.zero_arity()
    end
  end

  describe "cross-contract state access with dynamic facade" do
    test "4-arity fake on dynamic module reads contract-based Repo state" do
      alias DoubleDown.Repo
      alias DoubleDown.Test.Repo, as: TestRepo
      alias DoubleDown.Test.SimpleUser

      # Set up Repo with InMemory
      Double.fake(Repo, Repo.OpenInMemory)

      # Insert a record via Repo
      {:ok, _user} = TestRepo.insert(SimpleUser.changeset(%{name: "Alice"}))

      # Set up dynamic module with 4-arity fake that reads Repo state
      Double.fake(
        DynamicTarget,
        fn :greet, [_name], state, all_states ->
          repo_state = Map.get(all_states, Repo, %{})
          users = repo_state |> Map.get(SimpleUser, %{}) |> Map.values()
          names = Enum.map(users, & &1.name)
          {names, state}
        end,
        %{}
      )

      assert ["Alice"] = DynamicTarget.greet("ignored")
    end
  end

  describe "per-operation stubs with dynamic facade" do
    test "per-op stub overrides specific operation" do
      Double.stub(DynamicTarget, fn
        :greet, [name] -> "Fallback: #{name}"
        :add, [a, b] -> a + b
        :zero_arity, [] -> :fallback
      end)
      |> Double.stub(:greet, fn [name] -> "Stubbed: #{name}" end)

      assert "Stubbed: Alice" = DynamicTarget.greet("Alice")
      assert 5 = DynamicTarget.add(2, 3)
    end
  end

  describe "validation" do
    test "refuses DoubleDown contract modules" do
      assert_raise ArgumentError, ~r/DoubleDown contract/, fn ->
        DoubleDown.DynamicFacade.setup(DoubleDown.Repo)
      end
    end

    test "refuses DoubleDown internal modules" do
      assert_raise ArgumentError, ~r/DoubleDown internal/, fn ->
        DoubleDown.DynamicFacade.setup(DoubleDown.Contract.Dispatch)
      end
    end

    test "refuses NimbleOwnership" do
      assert_raise ArgumentError, ~r/NimbleOwnership/, fn ->
        DoubleDown.DynamicFacade.setup(NimbleOwnership)
      end
    end

    test "refuses Erlang modules" do
      assert_raise ArgumentError, ~r/Erlang/, fn ->
        DoubleDown.DynamicFacade.setup(:erlang)
      end
    end

    test "idempotent — setup twice is safe" do
      assert :ok = DoubleDown.DynamicFacade.setup(DynamicTarget)
    end
  end
end
