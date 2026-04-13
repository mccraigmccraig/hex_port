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

  # ── static_dispatch? ──────────────────────────────────────

  describe "static_dispatch?: true with config available" do
    test "facade calls impl directly — no config lookup at runtime" do
      # Set config so it's available at compile time
      Application.put_env(:double_down_static, DoubleDown.Test.Greeter,
        impl: DoubleDown.Test.Greeter.Impl
      )

      Code.compile_string("""
      defmodule DoubleDown.Test.StaticDispatchPort do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down_static,
          test_dispatch?: false,
          static_dispatch?: true
      end
      """)

      mod = DoubleDown.Test.StaticDispatchPort

      # Should call Greeter.Impl directly
      assert "Hello, Alice!" = apply(mod, :greet, ["Alice"])

      # Even after removing the config, static dispatch still works
      # (impl was resolved at compile time)
      Application.delete_env(:double_down_static, DoubleDown.Test.Greeter)

      assert "Hello, Bob!" = apply(mod, :greet, ["Bob"])
    end

    test "key helpers are still generated" do
      Application.put_env(:double_down_static2, DoubleDown.Test.Greeter,
        impl: DoubleDown.Test.Greeter.Impl
      )

      Code.compile_string("""
      defmodule DoubleDown.Test.StaticDispatchKeys do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down_static2,
          test_dispatch?: false,
          static_dispatch?: true
      end
      """)

      on_exit(fn ->
        Application.delete_env(:double_down_static2, DoubleDown.Test.Greeter)
      end)

      mod = DoubleDown.Test.StaticDispatchKeys

      assert function_exported?(mod, :__key__, 2)
    end
  end

  describe "static_dispatch?: true without config available" do
    test "falls back to call_config when no compile-time config" do
      Code.compile_string("""
      defmodule DoubleDown.Test.StaticNoConfigPort do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down_no_static_config,
          test_dispatch?: false,
          static_dispatch?: true
      end
      """)

      mod = DoubleDown.Test.StaticNoConfigPort

      # Set config at runtime — should work because it fell back to call_config
      Application.put_env(:double_down_no_static_config, DoubleDown.Test.Greeter,
        impl: DoubleDown.Test.Greeter.Impl
      )

      on_exit(fn ->
        Application.delete_env(:double_down_no_static_config, DoubleDown.Test.Greeter)
      end)

      assert "Hello, Alice!" = apply(mod, :greet, ["Alice"])
    end
  end

  describe "static_dispatch?: false" do
    test "uses call_config even when compile-time config is available" do
      Application.put_env(:double_down_no_static, DoubleDown.Test.Greeter,
        impl: DoubleDown.Test.Greeter.Impl
      )

      Code.compile_string("""
      defmodule DoubleDown.Test.NoStaticPort do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down_no_static,
          test_dispatch?: false,
          static_dispatch?: false
      end
      """)

      mod = DoubleDown.Test.NoStaticPort

      assert "Hello, Alice!" = apply(mod, :greet, ["Alice"])

      # Change config at runtime — should pick up the change (runtime dispatch)
      Application.put_env(:double_down_no_static, DoubleDown.Test.Greeter,
        impl: DoubleDown.Test.Greeter.Impl
      )

      on_exit(fn ->
        Application.delete_env(:double_down_no_static, DoubleDown.Test.Greeter)
      end)

      assert "Hello, Bob!" = apply(mod, :greet, ["Bob"])
    end
  end

  describe "static_dispatch? with test_dispatch?" do
    test "test_dispatch? takes precedence over static_dispatch?" do
      Application.put_env(:double_down_both, DoubleDown.Test.Greeter,
        impl: DoubleDown.Test.Greeter.Impl
      )

      Code.compile_string("""
      defmodule DoubleDown.Test.BothDispatchPort do
        use DoubleDown.Facade,
          contract: DoubleDown.Test.Greeter,
          otp_app: :double_down_both,
          test_dispatch?: true,
          static_dispatch?: true
      end
      """)

      on_exit(fn ->
        Application.delete_env(:double_down_both, DoubleDown.Test.Greeter)
      end)

      mod = DoubleDown.Test.BothDispatchPort

      # Test handler should take priority even though static_dispatch is true
      DoubleDown.Testing.set_fn_handler(DoubleDown.Test.Greeter, fn
        :greet, [name] -> "test-handler: #{name}"
      end)

      assert "test-handler: Alice" = apply(mod, :greet, ["Alice"])
    end
  end

  # ── Stateful handler exception safety ──────────────────────

  describe "stateful handler exceptions don't crash the ownership server" do
    test "raise inside stateful handler is transported to calling process" do
      handler = fn :greet, [_name], state ->
        raise RuntimeError, "boom from handler"
        {nil, state}
      end

      DoubleDown.Testing.set_stateful_handler(Greeter, handler, %{})

      assert_raise RuntimeError, ~r/boom from handler/, fn ->
        Greeter.Port.greet("Alice")
      end

      # Ownership server is still alive — subsequent calls work
      DoubleDown.Testing.set_fn_handler(Greeter, fn :greet, [name] -> "Hello #{name}" end)
      assert "Hello Bob" = Greeter.Port.greet("Bob")
    end

    test "throw inside stateful handler is transported to calling process" do
      handler = fn :greet, [_name], state ->
        throw(:boom_throw)
        {nil, state}
      end

      DoubleDown.Testing.set_stateful_handler(Greeter, handler, %{})

      assert catch_throw(Greeter.Port.greet("Alice")) == :boom_throw

      # Ownership server is still alive
      DoubleDown.Testing.set_fn_handler(Greeter, fn :greet, [name] -> "Hello #{name}" end)
      assert "Hello Bob" = Greeter.Port.greet("Bob")
    end

    test "exit inside stateful handler is transported to calling process" do
      handler = fn :greet, [_name], state ->
        exit(:boom_exit)
        {nil, state}
      end

      DoubleDown.Testing.set_stateful_handler(Greeter, handler, %{})

      assert catch_exit(Greeter.Port.greet("Alice")) == :boom_exit

      # Ownership server is still alive
      DoubleDown.Testing.set_fn_handler(Greeter, fn :greet, [name] -> "Hello #{name}" end)
      assert "Hello Bob" = Greeter.Port.greet("Bob")
    end
  end
end
