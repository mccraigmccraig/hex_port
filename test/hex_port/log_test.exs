defmodule HexPort.LogTest do
  use ExUnit.Case, async: true

  alias HexPort.Log
  alias HexPort.Test.Greeter
  alias HexPort.Test.Counter

  # Helper: set up a handler and enable logging for a contract,
  # then run the given function which dispatches calls.
  defp with_logged_calls(contract, handler_fn, dispatch_fn) do
    HexPort.Testing.set_fn_handler(contract, handler_fn)
    HexPort.Testing.enable_log(contract)
    dispatch_fn.()
  end

  # ── Builder tests ─────────────────────────────────────────

  describe "new/0" do
    test "returns empty accumulator" do
      assert %Log{expectations: []} = Log.new()
    end
  end

  describe "match/4..5" do
    test "appends expectations in declaration order" do
      fn1 = fn _ -> true end
      fn2 = fn _ -> true end

      acc =
        Log.match(Greeter, :greet, fn1)
        |> Log.match(Greeter, :fetch_greeting, fn2)

      assert [{:match, Greeter, :greet, ^fn1, 1}, {:match, Greeter, :fetch_greeting, ^fn2, 1}] =
               acc.expectations
    end

    test "with times: n" do
      fn1 = fn _ -> true end
      acc = Log.match(Greeter, :greet, fn1, times: 3)

      assert [{:match, Greeter, :greet, ^fn1, 3}] = acc.expectations
    end

    test "times: 0 raises" do
      assert_raise ArgumentError, ~r/times must be >= 1/, fn ->
        Log.match(Greeter, :greet, fn _ -> true end, times: 0)
      end
    end

    test "default first arg starts with new()" do
      acc = Log.match(Greeter, :greet, fn _ -> true end)
      assert %Log{} = acc
      assert length(acc.expectations) == 1
    end

    test "multi-contract accumulation" do
      acc =
        Log.match(Greeter, :greet, fn _ -> true end)
        |> Log.match(Counter, :increment, fn _ -> true end)

      contracts =
        Enum.map(acc.expectations, fn {:match, c, _, _, _} -> c end)

      assert Greeter in contracts
      assert Counter in contracts
    end
  end

  describe "reject/3" do
    test "appends reject expectation" do
      acc = Log.reject(Greeter, :greet)
      assert [{:reject, Greeter, :greet}] = acc.expectations
    end

    test "default first arg starts with new()" do
      acc = Log.reject(Greeter, :greet)
      assert %Log{} = acc
    end

    test "mixed match and reject" do
      acc =
        Log.match(Greeter, :greet, fn _ -> true end)
        |> Log.reject(Greeter, :fetch_greeting)

      assert [{:match, _, :greet, _, _}, {:reject, _, :fetch_greeting}] = acc.expectations
    end
  end

  # ── Loose-partial verify tests ────────────────────────────

  describe "verify!/2 loose mode" do
    test "raises on empty accumulator" do
      assert_raise ArgumentError, ~r/no expectations to verify/, fn ->
        Log.verify!(Log.new())
      end
    end

    test "single matcher satisfied" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
      end)

      assert :ok =
               Log.match(Greeter, :greet, fn
                 {Greeter, :greet, ["Alice"], "Hi, Alice!"} -> true
               end)
               |> Log.verify!()
    end

    test "multiple matchers in order" do
      with_logged_calls(
        Greeter,
        fn
          :greet, [name] -> "Hi, #{name}!"
          :fetch_greeting, [name] -> {:ok, "Hello, #{name}!"}
        end,
        fn ->
          Greeter.Port.greet("Alice")
          Greeter.Port.fetch_greeting("Bob")
        end
      )

      assert :ok =
               Log.match(Greeter, :greet, fn
                 {_, :greet, ["Alice"], _} -> true
               end)
               |> Log.match(Greeter, :fetch_greeting, fn
                 {_, :fetch_greeting, ["Bob"], _} -> true
               end)
               |> Log.verify!()
    end

    test "extra log entries between matchers are ignored" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
        Greeter.Port.greet("Bob")
        Greeter.Port.greet("Carol")
      end)

      # Match first and third, skip second
      assert :ok =
               Log.match(Greeter, :greet, fn
                 {_, _, ["Alice"], _} -> true
               end)
               |> Log.match(Greeter, :greet, fn
                 {_, _, ["Carol"], _} -> true
               end)
               |> Log.verify!()
    end

    test "times: n matching" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("A")
        Greeter.Port.greet("B")
        Greeter.Port.greet("C")
      end)

      assert :ok =
               Log.match(Greeter, :greet, fn {_, :greet, _, _} -> true end, times: 3)
               |> Log.verify!()
    end

    test "matcher with pattern matching on args" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
      end)

      assert :ok =
               Log.match(Greeter, :greet, fn
                 {_, _, [name], _} when is_binary(name) -> true
               end)
               |> Log.verify!()
    end

    test "matcher with pattern matching on results" do
      with_logged_calls(Greeter, fn :fetch_greeting, [name] -> {:ok, "Hello, #{name}!"} end, fn ->
        Greeter.Port.fetch_greeting("Alice")
      end)

      assert :ok =
               Log.match(Greeter, :fetch_greeting, fn
                 {_, _, _, {:ok, greeting}} when is_binary(greeting) -> true
               end)
               |> Log.verify!()
    end

    test "matcher with multiple clauses" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
      end)

      assert :ok =
               Log.match(Greeter, :greet, fn
                 {_, _, ["Bob"], _} -> true
                 {_, _, ["Alice"], _} -> true
               end)
               |> Log.verify!()
    end

    test "FunctionClauseError treated as no-match, scans forward" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
        Greeter.Port.greet("Bob")
      end)

      # Matcher only matches Bob — should skip Alice (FunctionClauseError) and find Bob
      assert :ok =
               Log.match(Greeter, :greet, fn
                 {_, _, ["Bob"], _} -> true
               end)
               |> Log.verify!()
    end

    test "unsatisfied matcher raises with descriptive error" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
      end)

      error =
        assert_raise RuntimeError, fn ->
          Log.match(Greeter, :greet, fn
            {_, _, ["Nobody"], _} -> true
          end)
          |> Log.verify!()
        end

      assert error.message =~ inspect(Greeter)
      assert error.message =~ "greet"
      assert error.message =~ "not found"
    end

    test "matchers for different operations matched independently" do
      with_logged_calls(
        Greeter,
        fn
          :greet, [name] -> "Hi, #{name}!"
          :fetch_greeting, [name] -> {:ok, "Hello, #{name}!"}
        end,
        fn ->
          Greeter.Port.fetch_greeting("Bob")
          Greeter.Port.greet("Alice")
        end
      )

      # greet declared first but appears second in log —
      # loose-partial matches per-contract, each operation scans independently
      assert :ok =
               Log.match(Greeter, :greet, fn {_, _, ["Alice"], _} -> true end)
               |> Log.match(Greeter, :fetch_greeting, fn {_, _, ["Bob"], _} -> true end)
               |> Log.verify!()
    end
  end

  # ── Reject tests ──────────────────────────────────────────

  describe "verify!/2 reject" do
    test "reject passes when operation absent from log" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
      end)

      assert :ok =
               Log.match(Greeter, :greet, fn _ -> true end)
               |> Log.reject(Greeter, :fetch_greeting)
               |> Log.verify!()
    end

    test "reject raises when operation present in log" do
      with_logged_calls(
        Greeter,
        fn
          :greet, [name] -> "Hi, #{name}!"
          :fetch_greeting, [name] -> {:ok, "Hello, #{name}!"}
        end,
        fn ->
          Greeter.Port.greet("Alice")
          Greeter.Port.fetch_greeting("Bob")
        end
      )

      error =
        assert_raise RuntimeError, fn ->
          Log.match(Greeter, :greet, fn _ -> true end)
          |> Log.reject(Greeter, :fetch_greeting)
          |> Log.verify!()
        end

      assert error.message =~ "reject"
      assert error.message =~ "fetch_greeting"
      assert error.message =~ "should not have been"
    end
  end

  # ── Strict mode tests ────────────────────────────────────

  describe "verify!/2 strict mode" do
    test "strict passes when all entries matched" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
        Greeter.Port.greet("Bob")
      end)

      assert :ok =
               Log.match(Greeter, :greet, fn _ -> true end, times: 2)
               |> Log.verify!(strict: true)
    end

    test "strict raises when unmatched entries exist" do
      with_logged_calls(
        Greeter,
        fn
          :greet, [name] -> "Hi, #{name}!"
          :fetch_greeting, [name] -> {:ok, "Hello, #{name}!"}
        end,
        fn ->
          Greeter.Port.greet("Alice")
          Greeter.Port.fetch_greeting("Bob")
        end
      )

      error =
        assert_raise RuntimeError, fn ->
          Log.match(Greeter, :greet, fn _ -> true end)
          |> Log.verify!(strict: true)
        end

      assert error.message =~ "strict"
      assert error.message =~ "unmatched"
      assert error.message =~ "fetch_greeting"
    end

    test "strict error message lists unmatched entries" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
        Greeter.Port.greet("Bob")
        Greeter.Port.greet("Carol")
      end)

      error =
        assert_raise RuntimeError, fn ->
          Log.match(Greeter, :greet, fn
            {_, _, ["Bob"], _} -> true
          end)
          |> Log.verify!(strict: true)
        end

      assert error.message =~ "Alice"
      assert error.message =~ "Carol"
    end
  end

  # ── Integration tests ─────────────────────────────────────

  describe "integration" do
    test "full pipeline: set handler, enable log, dispatch, match, verify" do
      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "Hi, #{name}!"
        :fetch_greeting, [name] -> {:ok, "Hello, #{name}!"}
      end)

      HexPort.Testing.enable_log(Greeter)

      Greeter.Port.greet("Alice")
      Greeter.Port.fetch_greeting("Bob")

      assert :ok =
               Log.match(Greeter, :greet, fn {_, _, ["Alice"], _} -> true end)
               |> Log.match(Greeter, :fetch_greeting, fn {_, _, ["Bob"], {:ok, _}} -> true end)
               |> Log.verify!()
    end

    test "multi-contract verification" do
      HexPort.Testing.set_fn_handler(Greeter, fn :greet, [name] -> "Hi, #{name}!" end)
      HexPort.Testing.enable_log(Greeter)

      HexPort.Testing.set_stateful_handler(
        Counter,
        fn
          :increment, [n], count -> {count + n, count + n}
          :get_count, [], count -> {count, count}
        end,
        0
      )

      HexPort.Testing.enable_log(Counter)

      Greeter.Port.greet("Alice")
      Counter.Port.increment(5)
      Counter.Port.get_count()

      assert :ok =
               Log.match(Greeter, :greet, fn {_, _, ["Alice"], _} -> true end)
               |> Log.match(Counter, :increment, fn {_, _, [5], 5} -> true end)
               |> Log.match(Counter, :get_count, fn {_, _, [], 5} -> true end)
               |> Log.verify!()
    end

    test "mix of match and reject expectations" do
      with_logged_calls(Greeter, fn :greet, [name] -> "Hi, #{name}!" end, fn ->
        Greeter.Port.greet("Alice")
      end)

      assert :ok =
               Log.match(Greeter, :greet, fn _ -> true end)
               |> Log.reject(Greeter, :fetch_greeting)
               |> Log.verify!()
    end

    test "used alongside HexPort.Handler" do
      HexPort.Handler.expect(Greeter, :greet, fn [name] -> "Hi, #{name}!" end)
      |> HexPort.Handler.expect(Greeter, :fetch_greeting, fn [name] ->
        {:ok, "Hello, #{name}!"}
      end)
      |> HexPort.Handler.install!()

      HexPort.Testing.enable_log(Greeter)

      Greeter.Port.greet("Alice")
      Greeter.Port.fetch_greeting("Bob")

      # Verify handler expectations
      HexPort.Handler.verify!()

      # Also verify log expectations
      assert :ok =
               Log.match(Greeter, :greet, fn {_, _, ["Alice"], _} -> true end)
               |> Log.match(Greeter, :fetch_greeting, fn {_, _, ["Bob"], {:ok, _}} -> true end)
               |> Log.verify!()
    end
  end
end
