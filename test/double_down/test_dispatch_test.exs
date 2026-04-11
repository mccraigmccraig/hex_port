defmodule DoubleDown.TestDispatchTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Test.Greeter

  # ── test_dispatch?: false ─────────────────────────────────

  describe "test_dispatch?: false" do
    test "facade uses call_config — bypasses NimbleOwnership test handlers" do
      Code.compile_string("""
      defmodule DoubleDown.Test.ConfigOnlyPort do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down,
          test_dispatch?: false
      end
      """)

      mod = DoubleDown.Test.ConfigOnlyPort

      # Set a test handler — it should be ignored because test_dispatch? is false
      DoubleDown.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "test-handler: #{name}"
      end)

      # Set application config so dispatch resolves
      Application.put_env(:double_down, Greeter, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:double_down, Greeter) end)

      # Should use config impl (Greeter.Impl), not the test handler
      assert "Hello, Alice!" = apply(mod, :greet, ["Alice"])
    end

    test "facade raises with production message when no config set" do
      Code.compile_string("""
      defmodule DoubleDown.Test.ConfigOnlyNoConfig do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down_no_config,
          test_dispatch?: false
      end
      """)

      mod = DoubleDown.Test.ConfigOnlyNoConfig

      # No config set — should raise
      assert_raise RuntimeError, ~r/No implementation configured|No test handler set/, fn ->
        apply(mod, :greet, ["Nobody"])
      end
    end

    test "key helpers are still generated" do
      Code.compile_string("""
      defmodule DoubleDown.Test.ConfigOnlyKeys do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down,
          test_dispatch?: false
      end
      """)

      mod = DoubleDown.Test.ConfigOnlyKeys

      assert function_exported?(mod, :__key__, 2)

      key = apply(mod, :__key__, [:greet, "world"])
      assert key == {Greeter, :greet, ["world"]}
    end

    test "bang variants are still generated" do
      Code.compile_string("""
      defmodule DoubleDown.Test.ConfigOnlyBang do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down,
          test_dispatch?: false
      end
      """)

      mod = DoubleDown.Test.ConfigOnlyBang

      assert function_exported?(mod, :fetch_greeting!, 1)
    end
  end

  # ── test_dispatch?: true ──────────────────────────────────

  describe "test_dispatch?: true" do
    test "facade uses call — test handlers work" do
      Code.compile_string("""
      defmodule DoubleDown.Test.TestDispatchTrue do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down,
          test_dispatch?: true
      end
      """)

      mod = DoubleDown.Test.TestDispatchTrue

      DoubleDown.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "test-dispatch-true: #{name}"
      end)

      assert "test-dispatch-true: Bob" = apply(mod, :greet, ["Bob"])
    end
  end

  # ── test_dispatch?: fn -> ... end ─────────────────────────

  describe "test_dispatch?: fn" do
    test "function returning true enables test dispatch" do
      Code.compile_string("""
      defmodule DoubleDown.Test.TestDispatchFnTrue do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down,
          test_dispatch?: fn -> true end
      end
      """)

      mod = DoubleDown.Test.TestDispatchFnTrue

      DoubleDown.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "fn-true: #{name}"
      end)

      assert "fn-true: Carol" = apply(mod, :greet, ["Carol"])
    end

    test "function returning false disables test dispatch" do
      Code.compile_string("""
      defmodule DoubleDown.Test.TestDispatchFnFalse do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down,
          test_dispatch?: fn -> false end
      end
      """)

      mod = DoubleDown.Test.TestDispatchFnFalse

      # Set test handler — should be ignored
      DoubleDown.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "fn-false-handler: #{name}"
      end)

      # Set config
      Application.put_env(:double_down, Greeter, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:double_down, Greeter) end)

      # Should use config impl, not test handler
      assert "Hello, Dave!" = apply(mod, :greet, ["Dave"])
    end
  end

  # ── default behaviour ─────────────────────────────────────

  describe "default (no test_dispatch? option)" do
    test "in test env, test dispatch is enabled by default" do
      Code.compile_string("""
      defmodule DoubleDown.Test.DefaultDispatch do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down
      end
      """)

      mod = DoubleDown.Test.DefaultDispatch

      DoubleDown.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "default: #{name}"
      end)

      # Default in test env should use test handler
      assert "default: Eve" = apply(mod, :greet, ["Eve"])
    end
  end

  # ── combined contract + facade with test_dispatch? ────────

  describe "combined contract + facade with test_dispatch?" do
    test "test_dispatch?: false works with combined module" do
      Code.compile_string("""
      defmodule DoubleDown.Test.CombinedConfigOnly do
        use DoubleDown.Facade, otp_app: :double_down_combined, test_dispatch?: false

        defcallback greet(name :: String.t()) :: String.t()
      end
      """)

      mod = DoubleDown.Test.CombinedConfigOnly

      # Set config
      Application.put_env(:double_down_combined, mod, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:double_down_combined, mod) end)

      # Set test handler — should be ignored
      DoubleDown.Testing.set_fn_handler(mod, fn
        :greet, [name] -> "should-not-see: #{name}"
      end)

      assert "Hello, Frank!" = apply(mod, :greet, ["Frank"])
    end

    test "test_dispatch?: true works with combined module" do
      Code.compile_string("""
      defmodule DoubleDown.Test.CombinedTestDispatch do
        use DoubleDown.Facade, otp_app: :double_down_combined, test_dispatch?: true

        defcallback greet(name :: String.t()) :: String.t()
      end
      """)

      mod = DoubleDown.Test.CombinedTestDispatch

      DoubleDown.Testing.set_fn_handler(mod, fn
        :greet, [name] -> "combined-test: #{name}"
      end)

      assert "combined-test: Grace" = apply(mod, :greet, ["Grace"])
    end
  end
end
