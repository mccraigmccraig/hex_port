defmodule HexPort.TestDispatchTest do
  use ExUnit.Case, async: true

  alias HexPort.Test.Greeter

  # ── test_dispatch?: false ─────────────────────────────────

  describe "test_dispatch?: false" do
    test "facade uses call_config — bypasses NimbleOwnership test handlers" do
      Code.compile_string("""
      defmodule HexPort.Test.ConfigOnlyPort do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port,
          test_dispatch?: false
      end
      """)

      mod = HexPort.Test.ConfigOnlyPort

      # Set a test handler — it should be ignored because test_dispatch? is false
      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "test-handler: #{name}"
      end)

      # Set application config so dispatch resolves
      Application.put_env(:hex_port, Greeter, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:hex_port, Greeter) end)

      # Should use config impl (Greeter.Impl), not the test handler
      assert "Hello, Alice!" = apply(mod, :greet, ["Alice"])
    end

    test "facade raises with production message when no config set" do
      Code.compile_string("""
      defmodule HexPort.Test.ConfigOnlyNoConfig do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port_no_config,
          test_dispatch?: false
      end
      """)

      mod = HexPort.Test.ConfigOnlyNoConfig

      # No config set — should raise
      assert_raise RuntimeError, ~r/No implementation configured|No test handler set/, fn ->
        apply(mod, :greet, ["Nobody"])
      end
    end

    test "key helpers are still generated" do
      Code.compile_string("""
      defmodule HexPort.Test.ConfigOnlyKeys do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port,
          test_dispatch?: false
      end
      """)

      mod = HexPort.Test.ConfigOnlyKeys

      assert function_exported?(mod, :__key__, 2)

      key = apply(mod, :__key__, [:greet, "world"])
      assert key == {Greeter, :greet, ["world"]}
    end

    test "bang variants are still generated" do
      Code.compile_string("""
      defmodule HexPort.Test.ConfigOnlyBang do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port,
          test_dispatch?: false
      end
      """)

      mod = HexPort.Test.ConfigOnlyBang

      assert function_exported?(mod, :fetch_greeting!, 1)
    end
  end

  # ── test_dispatch?: true ──────────────────────────────────

  describe "test_dispatch?: true" do
    test "facade uses call — test handlers work" do
      Code.compile_string("""
      defmodule HexPort.Test.TestDispatchTrue do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port,
          test_dispatch?: true
      end
      """)

      mod = HexPort.Test.TestDispatchTrue

      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "test-dispatch-true: #{name}"
      end)

      assert "test-dispatch-true: Bob" = apply(mod, :greet, ["Bob"])
    end
  end

  # ── test_dispatch?: fn -> ... end ─────────────────────────

  describe "test_dispatch?: fn" do
    test "function returning true enables test dispatch" do
      Code.compile_string("""
      defmodule HexPort.Test.TestDispatchFnTrue do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port,
          test_dispatch?: fn -> true end
      end
      """)

      mod = HexPort.Test.TestDispatchFnTrue

      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "fn-true: #{name}"
      end)

      assert "fn-true: Carol" = apply(mod, :greet, ["Carol"])
    end

    test "function returning false disables test dispatch" do
      Code.compile_string("""
      defmodule HexPort.Test.TestDispatchFnFalse do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port,
          test_dispatch?: fn -> false end
      end
      """)

      mod = HexPort.Test.TestDispatchFnFalse

      # Set test handler — should be ignored
      HexPort.Testing.set_fn_handler(Greeter, fn
        :greet, [name] -> "fn-false-handler: #{name}"
      end)

      # Set config
      Application.put_env(:hex_port, Greeter, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:hex_port, Greeter) end)

      # Should use config impl, not test handler
      assert "Hello, Dave!" = apply(mod, :greet, ["Dave"])
    end
  end

  # ── default behaviour ─────────────────────────────────────

  describe "default (no test_dispatch? option)" do
    test "in test env, test dispatch is enabled by default" do
      Code.compile_string("""
      defmodule HexPort.Test.DefaultDispatch do
        use HexPort.Facade,
          contract: HexPort.Test.Greeter,
          otp_app: :hex_port
      end
      """)

      mod = HexPort.Test.DefaultDispatch

      HexPort.Testing.set_fn_handler(Greeter, fn
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
      defmodule HexPort.Test.CombinedConfigOnly do
        use HexPort.Facade, otp_app: :hex_port_combined, test_dispatch?: false

        defport greet(name :: String.t()) :: String.t()
      end
      """)

      mod = HexPort.Test.CombinedConfigOnly

      # Set config
      Application.put_env(:hex_port_combined, mod, impl: Greeter.Impl)
      on_exit(fn -> Application.delete_env(:hex_port_combined, mod) end)

      # Set test handler — should be ignored
      HexPort.Testing.set_fn_handler(mod, fn
        :greet, [name] -> "should-not-see: #{name}"
      end)

      assert "Hello, Frank!" = apply(mod, :greet, ["Frank"])
    end

    test "test_dispatch?: true works with combined module" do
      Code.compile_string("""
      defmodule HexPort.Test.CombinedTestDispatch do
        use HexPort.Facade, otp_app: :hex_port_combined, test_dispatch?: true

        defport greet(name :: String.t()) :: String.t()
      end
      """)

      mod = HexPort.Test.CombinedTestDispatch

      HexPort.Testing.set_fn_handler(mod, fn
        :greet, [name] -> "combined-test: #{name}"
      end)

      assert "combined-test: Grace" = apply(mod, :greet, ["Grace"])
    end
  end
end
