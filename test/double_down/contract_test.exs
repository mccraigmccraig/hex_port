defmodule DoubleDown.ContractTest do
  use ExUnit.Case, async: true

  # ── Callback generation ──────────────────────────────────

  describe "callback generation" do
    test "contract module declares @callbacks for each defcallback" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(DoubleDown.Test.Greeter)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:greet, 1} in callback_names
      assert {:fetch_greeting, 1} in callback_names
    end

    test "callbacks have correct arity" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(DoubleDown.Test.Greeter)
      callback_map = Map.new(callbacks, fn {name_arity, specs} -> {name_arity, specs} end)

      assert Map.has_key?(callback_map, {:greet, 1})
      assert Map.has_key?(callback_map, {:fetch_greeting, 1})
    end

    test "zero-arg operations produce arity-0 callbacks" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(DoubleDown.Test.ZeroArg)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:health_check, 0} in callback_names
      assert {:get_version, 0} in callback_names
    end

    test "multi-param operations produce correct arity callbacks" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(DoubleDown.Test.MultiParam)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:find, 3} in callback_names
    end

    test "contract can be implemented (Greeter.Impl satisfies @behaviour)" do
      # The test contract Greeter.Impl uses @behaviour DoubleDown.Test.Greeter
      # and compiles without warnings — this is sufficient proof
      assert DoubleDown.Test.Greeter.Impl.greet("world") == "Hello, world!"
      assert DoubleDown.Test.Greeter.Impl.fetch_greeting("world") == {:ok, "Hello, world!"}
    end
  end

  # ── Port facade generation ────────────────────────────────

  describe "Port facade generation" do
    test "generates a .Port sub-module" do
      assert {:module, DoubleDown.Test.Greeter.Port} =
               Code.ensure_loaded(DoubleDown.Test.Greeter.Port)
    end

    test "Port defines functions matching each defcallback" do
      {:module, _} = Code.ensure_loaded(DoubleDown.Test.Greeter.Port)
      assert function_exported?(DoubleDown.Test.Greeter.Port, :greet, 1)
      assert function_exported?(DoubleDown.Test.Greeter.Port, :fetch_greeting, 1)
    end

    test "Port facade dispatches through DoubleDown.Dispatch" do
      DoubleDown.Testing.set_fn_handler(DoubleDown.Test.Greeter, fn
        :greet, [name] -> "Dispatched: #{name}"
      end)

      assert DoubleDown.Test.Greeter.Port.greet("test") == "Dispatched: test"
    end

    test "Port facade passes all arguments" do
      DoubleDown.Testing.set_fn_handler(DoubleDown.Test.MultiParam, fn
        :find, [tenant, type, id] -> {:ok, %{tenant: tenant, type: type, id: id}}
      end)

      assert {:ok, %{tenant: "t1", type: :user, id: "u1"}} =
               DoubleDown.Test.MultiParam.Port.find("t1", :user, "u1")
    end

    test "zero-arg Port functions work" do
      DoubleDown.Testing.set_fn_handler(DoubleDown.Test.ZeroArg, fn
        :health_check, [] -> :ok
        :get_version, [] -> {:ok, "1.0.0"}
      end)

      assert :ok = DoubleDown.Test.ZeroArg.Port.health_check()
      assert {:ok, "1.0.0"} = DoubleDown.Test.ZeroArg.Port.get_version()
    end

    test "Facade module has @moduledoc" do
      {:docs_v1, _anno, _lang, _format, module_doc, _meta, _docs} =
        Code.fetch_docs(DoubleDown.Test.Greeter.Port)

      assert %{"en" => doc} = module_doc
      assert doc =~ "Dispatch facade"
      assert doc =~ "DoubleDown.Test.Greeter"
    end

    test "Port stores @double_down_contract module attribute" do
      # The contract module reference is captured and used by dispatch
      # We verify this indirectly — dispatch resolves using it.
      DoubleDown.Testing.set_fn_handler(DoubleDown.Test.Greeter, fn
        :greet, [name] -> "via-contract: #{name}"
      end)

      assert DoubleDown.Test.Greeter.Port.greet("check") == "via-contract: check"
    end
  end

  # ── Key helpers ───────────────────────────────────────────

  describe "key helpers" do
    test "__key__/2 generates a canonical key tuple" do
      key = DoubleDown.Test.Greeter.Port.__key__(:greet, "world")

      assert key == {DoubleDown.Test.Greeter, :greet, ["world"]}
    end

    test "__key__/2 with zero args" do
      key = DoubleDown.Test.ZeroArg.Port.__key__(:health_check)

      assert key == {DoubleDown.Test.ZeroArg, :health_check, []}
    end

    test "__key__/2 with multiple args" do
      key = DoubleDown.Test.MultiParam.Port.__key__(:find, "t1", :user, "u1")

      assert key == {DoubleDown.Test.MultiParam, :find, ["t1", :user, "u1"]}
    end

    test "__key__/2 normalizes map argument order" do
      key1 = DoubleDown.Test.Greeter.Port.__key__(:greet, %{b: 2, a: 1})
      key2 = DoubleDown.Test.Greeter.Port.__key__(:greet, %{a: 1, b: 2})

      assert key1 == key2
    end

    test "key helpers are defined for each operation" do
      {:module, _} = Code.ensure_loaded(DoubleDown.Test.Greeter.Port)
      {:module, _} = Code.ensure_loaded(DoubleDown.Test.Counter.Port)

      # Greeter has two operations, each gets a key helper
      assert function_exported?(DoubleDown.Test.Greeter.Port, :__key__, 2)

      # Counter: increment(amount) → __key__/2, get_count() → __key__/1
      assert function_exported?(DoubleDown.Test.Counter.Port, :__key__, 2)
      assert function_exported?(DoubleDown.Test.Counter.Port, :__key__, 1)
    end
  end

  # ── __callbacks__/0 introspection ───────────────────

  describe "__callbacks__/0 introspection" do
    test "returns list of operation maps" do
      ops = DoubleDown.Test.Greeter.__callbacks__()

      assert is_list(ops)
      assert length(ops) == 2
    end

    test "each operation has required keys" do
      [op | _] = DoubleDown.Test.Greeter.__callbacks__()

      assert Map.has_key?(op, :name)
      assert Map.has_key?(op, :params)
      assert Map.has_key?(op, :param_types)
      assert Map.has_key?(op, :return_type)
      assert Map.has_key?(op, :pre_dispatch)
      assert Map.has_key?(op, :arity)
    end

    test "reports correct operation names" do
      ops = DoubleDown.Test.Greeter.__callbacks__()
      names = Enum.map(ops, & &1.name)

      assert :greet in names
      assert :fetch_greeting in names
    end

    test "reports correct param names" do
      ops = DoubleDown.Test.MultiParam.__callbacks__()
      [find_op] = ops

      assert find_op.params == [:tenant, :type, :id]
      assert find_op.arity == 3
    end

    test "zero-arg operations report arity 0" do
      ops = DoubleDown.Test.ZeroArg.__callbacks__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      assert op_map[:health_check].arity == 0
      assert op_map[:health_check].params == []
    end
  end

  # ── @doc propagation ──────────────────────────────────────

  describe "@doc propagation" do
    test "user @doc is propagated to Port facade function" do
      {:docs_v1, _anno, _lang, _format, _module_doc, _meta, docs} =
        Code.fetch_docs(DoubleDown.Test.Documented.Port)

      # Find the get_user/1 function doc
      get_user_doc =
        Enum.find(docs, fn
          {{:function, :get_user, 1}, _anno, _sig, _doc, _meta} -> true
          _ -> false
        end)

      assert get_user_doc != nil

      {{:function, :get_user, 1}, _anno, _sig, doc_content, _meta} = get_user_doc
      assert %{"en" => doc} = doc_content
      assert doc =~ "Fetches a user by their ID."
    end

    test "operations without @doc get default documentation" do
      {:docs_v1, _anno, _lang, _format, _module_doc, _meta, docs} =
        Code.fetch_docs(DoubleDown.Test.Documented.Port)

      list_users_doc =
        Enum.find(docs, fn
          {{:function, :list_users, 0}, _anno, _sig, _doc, _meta} -> true
          _ -> false
        end)

      assert list_users_doc != nil

      {{:function, :list_users, 0}, _anno, _sig, doc_content, _meta} = list_users_doc
      assert %{"en" => doc} = doc_content
      assert doc =~ "Port operation"
    end
  end

  # ── Idempotency ───────────────────────────────────────────

  describe "idempotency" do
    test "use DoubleDown.Contract twice in the same module compiles and works correctly" do
      modules =
        Code.compile_string("""
        defmodule DoubleDown.Test.DoubleUse do
          use DoubleDown.Contract
          use DoubleDown.Contract

          defcallback hello(name :: String.t()) :: String.t()
          defcallback ping() :: :pong
        end
        """)

      # Should produce just the contract module (no Behaviour submodule)
      mod_names = Enum.map(modules, fn {mod, _} -> mod end)
      assert DoubleDown.Test.DoubleUse in mod_names

      # Operations are correct (not duplicated)
      mod = DoubleDown.Test.DoubleUse
      ops = apply(mod, :__callbacks__, [])
      assert length(ops) == 2
      op_names = Enum.map(ops, & &1.name)
      assert :hello in op_names
      assert :ping in op_names
    end
  end

  # ── Combined contract + facade ────────────────────────────

  describe "combined contract and facade on same module" do
    test "explicit contract: __MODULE__ compiles and works" do
      modules =
        Code.compile_string("""
        defmodule DoubleDown.Test.Combined do
          use DoubleDown.Contract
          use DoubleDown.Facade, contract: DoubleDown.Test.Combined, otp_app: :double_down_test

          defcallback greet(name :: String.t()) :: String.t()
          defcallback ping() :: :pong
        end
        """)

      mod_names = Enum.map(modules, fn {mod, _} -> mod end)
      assert DoubleDown.Test.Combined in mod_names

      mod = DoubleDown.Test.Combined

      # Has both callbacks and facade functions
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # Has __callbacks__
      ops = apply(mod, :__callbacks__, [])
      assert length(ops) == 2

      # Facade functions exist
      assert function_exported?(mod, :greet, 1)
      assert function_exported?(mod, :ping, 0)
    end

    test "omitting contract: defaults to __MODULE__ and implies use DoubleDown.Contract" do
      Code.compile_string("""
      defmodule DoubleDown.Test.CombinedImplicit do
        use DoubleDown.Facade, otp_app: :double_down_test

        defcallback greet(name :: String.t()) :: String.t()
        defcallback ping() :: :pong
      end
      """)

      mod = DoubleDown.Test.CombinedImplicit

      # Has callbacks (Contract was implicitly used)
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # Has __callbacks__
      ops = apply(mod, :__callbacks__, [])
      assert length(ops) == 2

      # Facade functions exist
      assert function_exported?(mod, :greet, 1)
      assert function_exported?(mod, :ping, 0)
    end

    test "facade dispatches correctly via test handler" do
      Code.compile_string("""
      defmodule DoubleDown.Test.CombinedDispatch do
        use DoubleDown.Facade, otp_app: :double_down_test

        defcallback greet(name :: String.t()) :: String.t()
      end
      """)

      mod = DoubleDown.Test.CombinedDispatch

      DoubleDown.Testing.set_fn_handler(mod, fn
        :greet, ["Alice"] -> "Hello, Alice!"
      end)

      assert "Hello, Alice!" = apply(mod, :greet, ["Alice"])
    end
  end

  # ── Compile errors ────────────────────────────────────────

  describe "compile errors" do
    test "raises on untyped parameter" do
      assert_raise CompileError, ~r/must be typed/, fn ->
        Code.compile_string("""
        defmodule DoubleDown.Test.BadUntyped do
          use DoubleDown.Contract
          defcallback bad_op(name) :: String.t()
        end
        """)
      end
    end

    test "raises on default arguments" do
      assert_raise CompileError, ~r/does not support default arguments/, fn ->
        Code.compile_string("""
        defmodule DoubleDown.Test.BadDefaults do
          use DoubleDown.Contract
          defcallback bad_op(name :: String.t() \\\\ "default") :: String.t()
        end
        """)
      end
    end

    test "raises when no defcallback declarations" do
      assert_raise CompileError, ~r/has no defcallback declarations/, fn ->
        Code.compile_string("""
        defmodule DoubleDown.Test.BadEmpty do
          use DoubleDown.Contract
        end
        """)
      end
    end

    test "raises on missing return type annotation" do
      assert_raise CompileError, ~r/invalid defcallback syntax/, fn ->
        Code.compile_string("""
        defmodule DoubleDown.Test.BadNoReturn do
          use DoubleDown.Contract
          defcallback bad_op(name :: String.t())
        end
        """)
      end
    end
  end

  # ── Type alias expansion ──────────────────────────────────

  describe "type alias expansion" do
    test "param_types in __callbacks__ contain fully-qualified module names" do
      ops = DoubleDown.Test.AliasedTypes.__callbacks__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      # list_widgets has param type Widget.t() — should be expanded to
      # DoubleDown.Test.Deep.Nested.Widget.t()
      [filter_type] = op_map[:list_widgets].param_types

      # The type AST should reference the fully-qualified module,
      # not the aliased short name. Convert to string for assertion.
      type_string = Macro.to_string(filter_type)
      assert type_string =~ "DoubleDown.Test.Deep.Nested.Widget"
      refute type_string =~ ~r/(?<!\.)Widget\.t/
    end

    test "return_type in __callbacks__ contains fully-qualified module names" do
      ops = DoubleDown.Test.AliasedTypes.__callbacks__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      # get_widget returns {:ok, Widget.t()} | {:error, term()}
      return_string = Macro.to_string(op_map[:get_widget].return_type)
      assert return_string =~ "DoubleDown.Test.Deep.Nested.Widget"
      refute return_string =~ ~r/(?<!\.)Widget\.t/

      # list_widgets returns [Widget.t()]
      list_return_string = Macro.to_string(op_map[:list_widgets].return_type)
      assert list_return_string =~ "DoubleDown.Test.Deep.Nested.Widget"
    end

    test "Port module with aliased types compiles and has correct specs" do
      {:ok, specs} = Code.Typespec.fetch_specs(DoubleDown.Test.AliasedTypes.Port)
      spec_names = Enum.map(specs, fn {name_arity, _} -> name_arity end)

      assert {:get_widget, 1} in spec_names
      assert {:list_widgets, 1} in spec_names
    end

    test "Port facade with aliased types dispatches correctly" do
      DoubleDown.Testing.set_fn_handler(DoubleDown.Test.AliasedTypes, fn
        :get_widget, [id] -> {:ok, %DoubleDown.Test.Deep.Nested.Widget{id: id, label: "test"}}
        :list_widgets, [_filter] -> []
      end)

      assert {:ok, %DoubleDown.Test.Deep.Nested.Widget{id: "w1"}} =
               DoubleDown.Test.AliasedTypes.Port.get_widget("w1")

      assert [] =
               DoubleDown.Test.AliasedTypes.Port.list_widgets(%DoubleDown.Test.Deep.Nested.Widget{
                 id: "f",
                 label: "filter"
               })
    end
  end

  # ── @spec generation ──────────────────────────────────────

  describe "@spec generation" do
    test "Port functions have @spec" do
      {:ok, specs} = Code.Typespec.fetch_specs(DoubleDown.Test.Greeter.Port)
      spec_names = Enum.map(specs, fn {name_arity, _} -> name_arity end)

      assert {:greet, 1} in spec_names
      assert {:fetch_greeting, 1} in spec_names
    end

    test "zero-arg functions have @spec" do
      {:ok, specs} = Code.Typespec.fetch_specs(DoubleDown.Test.ZeroArg.Port)
      spec_names = Enum.map(specs, fn {name_arity, _} -> name_arity end)

      assert {:health_check, 0} in spec_names
      assert {:get_version, 0} in spec_names
    end
  end
end
