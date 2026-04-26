defmodule DoubleDown.BehaviourFacadeTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Test.VanillaBehaviour
  alias DoubleDown.Test.BareTypesBehaviour
  alias DoubleDown.Test.WhenClauseBehaviour
  alias DoubleDown.Test.MixedParamsBehaviour
  alias DoubleDown.Test.ZeroArgBehaviour

  # -------------------------------------------------------------------
  # Facade generation
  # -------------------------------------------------------------------

  describe "facade generation" do
    test "generates functions with correct arities for annotated-param behaviour" do
      Code.ensure_loaded!(VanillaBehaviour.Port)
      assert function_exported?(VanillaBehaviour.Port, :get_item, 1)
      assert function_exported?(VanillaBehaviour.Port, :list_items, 0)
      assert function_exported?(VanillaBehaviour.Port, :create_item, 2)
    end

    test "generates functions for bare-type behaviour" do
      Code.ensure_loaded!(BareTypesBehaviour.Port)
      assert function_exported?(BareTypesBehaviour.Port, :fetch, 2)
    end

    test "generates functions for when-clause behaviour" do
      Code.ensure_loaded!(WhenClauseBehaviour.Port)
      assert function_exported?(WhenClauseBehaviour.Port, :transform, 1)
    end

    test "generates functions for mixed-params behaviour" do
      Code.ensure_loaded!(MixedParamsBehaviour.Port)
      assert function_exported?(MixedParamsBehaviour.Port, :mixed, 3)
    end

    test "generates functions for zero-arg behaviour" do
      Code.ensure_loaded!(ZeroArgBehaviour.Port)
      assert function_exported?(ZeroArgBehaviour.Port, :ping, 0)
      assert function_exported?(ZeroArgBehaviour.Port, :health_check, 0)
    end
  end

  # -------------------------------------------------------------------
  # Dispatch with fn handler
  # -------------------------------------------------------------------

  describe "fn handler dispatch" do
    test "dispatches to a function handler" do
      DoubleDown.Testing.set_stateless_handler(VanillaBehaviour, fn _contract, operation, args ->
        case {operation, args} do
          {:get_item, [id]} -> {:ok, %{id: id}}
          {:list_items, []} -> [%{id: "test"}]
          {:create_item, [attrs, _opts]} -> {:ok, attrs}
        end
      end)

      assert {:ok, %{id: "42"}} = VanillaBehaviour.Port.get_item("42")
      assert [%{id: "test"}] = VanillaBehaviour.Port.list_items()
      assert {:ok, %{name: "thing"}} = VanillaBehaviour.Port.create_item(%{name: "thing"}, [])
    end

    test "dispatches zero-arg callbacks via fn handler" do
      DoubleDown.Testing.set_stateless_handler(ZeroArgBehaviour, fn _contract, operation, args ->
        case {operation, args} do
          {:ping, []} -> :pong
          {:health_check, []} -> {:ok, %{status: :healthy}}
        end
      end)

      assert :pong = ZeroArgBehaviour.Port.ping()
      assert {:ok, %{status: :healthy}} = ZeroArgBehaviour.Port.health_check()
    end

    test "dispatches bare-type callbacks via fn handler" do
      DoubleDown.Testing.set_stateless_handler(BareTypesBehaviour, fn _contract, :fetch, [key, _opts] ->
        {:ok, key}
      end)

      assert {:ok, "mykey"} = BareTypesBehaviour.Port.fetch("mykey", timeout: 5000)
    end

    test "dispatches when-clause callbacks via fn handler" do
      DoubleDown.Testing.set_stateless_handler(WhenClauseBehaviour, fn _contract, :transform, [input] ->
        String.upcase(input)
      end)

      assert "HELLO" = WhenClauseBehaviour.Port.transform("hello")
    end
  end

  # -------------------------------------------------------------------
  # Dispatch with module handler
  # -------------------------------------------------------------------

  describe "module handler dispatch" do
    test "dispatches to a module implementing the behaviour" do
      DoubleDown.Testing.set_handler(VanillaBehaviour, VanillaBehaviour.Impl)

      assert {:ok, %{id: "99"}} = VanillaBehaviour.Port.get_item("99")
      assert [%{id: "1"}, %{id: "2"}] = VanillaBehaviour.Port.list_items()
      assert {:ok, %{x: 1}} = VanillaBehaviour.Port.create_item(%{x: 1}, [])
    end
  end

  # -------------------------------------------------------------------
  # Key helpers
  # -------------------------------------------------------------------

  describe "key helpers" do
    test "generates __key__ for single-param callback" do
      key = VanillaBehaviour.Port.__key__(:get_item, "42")
      assert key == DoubleDown.Contract.Dispatch.key(VanillaBehaviour, :get_item, ["42"])
    end

    test "generates __key__ for multi-param callback" do
      key = VanillaBehaviour.Port.__key__(:create_item, %{a: 1}, verbose: true)

      assert key ==
               DoubleDown.Contract.Dispatch.key(VanillaBehaviour, :create_item, [
                 %{a: 1},
                 [verbose: true]
               ])
    end

    test "generates __key__ for zero-arg callback" do
      key = ZeroArgBehaviour.Port.__key__(:ping)
      assert key == DoubleDown.Contract.Dispatch.key(ZeroArgBehaviour, :ping, [])
    end
  end

  # -------------------------------------------------------------------
  # @spec generation
  # -------------------------------------------------------------------

  describe "spec generation" do
    test "generates @spec for annotated-param callbacks" do
      {:ok, specs} = Code.Typespec.fetch_specs(VanillaBehaviour.Port)

      spec_map = Map.new(specs, fn {{name, arity}, _clauses} -> {{name, arity}, true} end)

      assert spec_map[{:get_item, 1}]
      assert spec_map[{:list_items, 0}]
      assert spec_map[{:create_item, 2}]
    end

    test "generates @spec for bare-type callbacks" do
      {:ok, specs} = Code.Typespec.fetch_specs(BareTypesBehaviour.Port)
      spec_map = Map.new(specs, fn {{name, arity}, _clauses} -> {{name, arity}, true} end)

      assert spec_map[{:fetch, 2}]
    end

    test "generates @spec for zero-arg callbacks" do
      {:ok, specs} = Code.Typespec.fetch_specs(ZeroArgBehaviour.Port)
      spec_map = Map.new(specs, fn {{name, arity}, _clauses} -> {{name, arity}, true} end)

      assert spec_map[{:ping, 0}]
      assert spec_map[{:health_check, 0}]
    end
  end

  # -------------------------------------------------------------------
  # Compile error cases
  # -------------------------------------------------------------------

  describe "compile errors" do
    test "raises when :behaviour option is missing" do
      assert_raise CompileError, ~r/requires a :behaviour option/, fn ->
        Code.compile_string("""
        defmodule BehaviourFacadeTest.MissingOpt do
          use DoubleDown.BehaviourFacade, otp_app: :test
        end
        """)
      end
    end

    test "raises when behaviour is same module (self-ref)" do
      assert_raise CompileError, ~r/cannot be used in the same module/, fn ->
        Code.compile_string("""
        defmodule BehaviourFacadeTest.SelfRef do
          use DoubleDown.BehaviourFacade,
            behaviour: BehaviourFacadeTest.SelfRef,
            otp_app: :test
        end
        """)
      end
    end

    test "raises when behaviour module is not loaded" do
      assert_raise CompileError, ~r/not loaded/, fn ->
        Code.compile_string("""
        defmodule BehaviourFacadeTest.Unloaded do
          use DoubleDown.BehaviourFacade,
            behaviour: DoesNotExist.AtAll,
            otp_app: :test
        end
        """)
      end
    end

    test "raises when module has no callbacks" do
      assert_raise CompileError, ~r/no @callback declarations/, fn ->
        Code.compile_string("""
        defmodule BehaviourFacadeTest.NoCallbacks do
          use DoubleDown.BehaviourFacade,
            behaviour: DoubleDown.Test.NotABehaviour,
            otp_app: :test
        end
        """)
      end
    end
  end

  # -------------------------------------------------------------------
  # Config dispatch (uses Application.put_env for test isolation)
  # -------------------------------------------------------------------

  describe "config dispatch" do
    test "dispatches to configured implementation" do
      # Temporarily set config for the behaviour
      Application.put_env(:double_down, VanillaBehaviour, impl: VanillaBehaviour.Impl)

      on_exit(fn ->
        Application.delete_env(:double_down, VanillaBehaviour)
      end)

      # Build a fresh facade that uses config dispatch (no test handler set)
      # We can't easily test config dispatch through the Port module because
      # test_dispatch? is true in test env. Instead, test via Dispatch directly.
      result =
        DoubleDown.Contract.Dispatch.call_config(
          :double_down,
          VanillaBehaviour,
          :get_item,
          ["config-test"]
        )

      assert {:ok, %{id: "config-test"}} = result
    end
  end
end
