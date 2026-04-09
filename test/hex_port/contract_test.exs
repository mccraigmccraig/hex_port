defmodule HexPort.ContractTest do
  use ExUnit.Case, async: true

  # ── Callback generation ──────────────────────────────────

  describe "callback generation" do
    test "contract module declares @callbacks for each defport" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.Greeter)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:greet, 1} in callback_names
      assert {:fetch_greeting, 1} in callback_names
    end

    test "callbacks have correct arity" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.Greeter)
      callback_map = Map.new(callbacks, fn {name_arity, specs} -> {name_arity, specs} end)

      assert Map.has_key?(callback_map, {:greet, 1})
      assert Map.has_key?(callback_map, {:fetch_greeting, 1})
    end

    test "zero-arg operations produce arity-0 callbacks" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.ZeroArg)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:health_check, 0} in callback_names
      assert {:get_version, 0} in callback_names
    end

    test "multi-param operations produce correct arity callbacks" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.MultiParam)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:find, 3} in callback_names
    end

    test "contract can be implemented (Greeter.Impl satisfies @behaviour)" do
      # The test contract Greeter.Impl uses @behaviour HexPort.Test.Greeter
      # and compiles without warnings — this is sufficient proof
      assert HexPort.Test.Greeter.Impl.greet("world") == "Hello, world!"
      assert HexPort.Test.Greeter.Impl.fetch_greeting("world") == {:ok, "Hello, world!"}
    end
  end

  # ── Port facade generation ────────────────────────────────

  describe "Port facade generation" do
    test "generates a .Port sub-module" do
      assert {:module, HexPort.Test.Greeter.Port} =
               Code.ensure_loaded(HexPort.Test.Greeter.Port)
    end

    test "Port defines functions matching each defport" do
      assert function_exported?(HexPort.Test.Greeter.Port, :greet, 1)
      assert function_exported?(HexPort.Test.Greeter.Port, :fetch_greeting, 1)
    end

    test "Port facade dispatches through HexPort.Dispatch" do
      HexPort.Testing.set_fn_handler(HexPort.Test.Greeter, fn
        :greet, [name] -> "Dispatched: #{name}"
      end)

      assert HexPort.Test.Greeter.Port.greet("test") == "Dispatched: test"
    end

    test "Port facade passes all arguments" do
      HexPort.Testing.set_fn_handler(HexPort.Test.MultiParam, fn
        :find, [tenant, type, id] -> {:ok, %{tenant: tenant, type: type, id: id}}
      end)

      assert {:ok, %{tenant: "t1", type: :user, id: "u1"}} =
               HexPort.Test.MultiParam.Port.find("t1", :user, "u1")
    end

    test "zero-arg Port functions work" do
      HexPort.Testing.set_fn_handler(HexPort.Test.ZeroArg, fn
        :health_check, [] -> :ok
        :get_version, [] -> {:ok, "1.0.0"}
      end)

      assert :ok = HexPort.Test.ZeroArg.Port.health_check()
      assert {:ok, "1.0.0"} = HexPort.Test.ZeroArg.Port.get_version()
    end

    test "Facade module has @moduledoc" do
      {:docs_v1, _anno, _lang, _format, module_doc, _meta, _docs} =
        Code.fetch_docs(HexPort.Test.Greeter.Port)

      assert %{"en" => doc} = module_doc
      assert doc =~ "Dispatch facade"
      assert doc =~ "HexPort.Test.Greeter"
    end

    test "Port stores @hex_port_contract module attribute" do
      # The contract module reference is captured and used by dispatch
      # We verify this indirectly — dispatch resolves using it.
      HexPort.Testing.set_fn_handler(HexPort.Test.Greeter, fn
        :greet, [name] -> "via-contract: #{name}"
      end)

      assert HexPort.Test.Greeter.Port.greet("check") == "via-contract: check"
    end
  end

  # ── Bang variant generation ───────────────────────────────

  describe "bang variant generation" do
    setup do
      HexPort.Testing.set_fn_handler(HexPort.Test.BangVariants, fn
        :auto_bang, [id] -> {:ok, "auto-#{id}"}
        :forced_bang, [id] -> "forced-#{id}"
        :suppressed_bang, [id] -> {:ok, "suppressed-#{id}"}
        :custom_bang, [id] -> "custom-#{id}"
        :no_bang, [id] -> "plain-#{id}"
      end)

      :ok
    end

    test "auto-detected bang: generates bang for {:ok, T} | {:error, T} return type" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.BangVariants.Port)
      assert function_exported?(HexPort.Test.BangVariants.Port, :auto_bang!, 1)
      assert "auto-test" = HexPort.Test.BangVariants.Port.auto_bang!("test")
    end

    test "auto-detected bang: raises on error" do
      HexPort.Testing.set_fn_handler(HexPort.Test.BangVariants, fn
        :auto_bang, [_id] -> {:error, :not_found}
      end)

      assert_raise RuntimeError, ~r/auto_bang failed/, fn ->
        HexPort.Test.BangVariants.Port.auto_bang!("test")
      end
    end

    test "forced bang: generates bang even without {:ok, T} return type" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.BangVariants.Port)
      assert function_exported?(HexPort.Test.BangVariants.Port, :forced_bang!, 1)
    end

    test "forced bang: unwraps {:ok, value}" do
      HexPort.Testing.set_fn_handler(HexPort.Test.BangVariants, fn
        :forced_bang, [id] -> {:ok, "wrapped-#{id}"}
      end)

      assert "wrapped-test" = HexPort.Test.BangVariants.Port.forced_bang!("test")
    end

    test "forced bang: raises on {:error, reason}" do
      HexPort.Testing.set_fn_handler(HexPort.Test.BangVariants, fn
        :forced_bang, [_id] -> {:error, :boom}
      end)

      assert_raise RuntimeError, ~r/forced_bang failed/, fn ->
        HexPort.Test.BangVariants.Port.forced_bang!("test")
      end
    end

    test "suppressed bang: does not generate a bang variant" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.BangVariants.Port)
      refute function_exported?(HexPort.Test.BangVariants.Port, :suppressed_bang!, 1)
    end

    test "custom bang: generates bang with custom unwrap function" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.BangVariants.Port)
      assert function_exported?(HexPort.Test.BangVariants.Port, :custom_bang!, 1)

      # custom_bang returns "custom-test", custom unwrap maps non-nil to {:ok, value}
      assert "custom-test" = HexPort.Test.BangVariants.Port.custom_bang!("test")
    end

    test "custom bang: raises when custom unwrap returns {:error, reason}" do
      HexPort.Testing.set_fn_handler(HexPort.Test.BangVariants, fn
        :custom_bang, [_id] -> nil
      end)

      # custom unwrap maps nil to {:error, :not_found}
      assert_raise RuntimeError, ~r/custom_bang failed/, fn ->
        HexPort.Test.BangVariants.Port.custom_bang!("test")
      end
    end

    test "no bang: plain return type without bang option gets no bang variant" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.BangVariants.Port)
      refute function_exported?(HexPort.Test.BangVariants.Port, :no_bang!, 1)
    end

    test "Greeter auto-detects bang for fetch_greeting but not greet" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.Greeter.Port)
      assert function_exported?(HexPort.Test.Greeter.Port, :fetch_greeting!, 1)
      refute function_exported?(HexPort.Test.Greeter.Port, :greet!, 1)
    end

    test "bang variants call the non-bang function (no double dispatch)" do
      HexPort.Testing.set_fn_handler(HexPort.Test.Greeter, fn
        :fetch_greeting, [name] -> {:ok, "Hello, #{name}!"}
      end)

      HexPort.Testing.enable_log(HexPort.Test.Greeter)

      # Call bang variant
      assert "Hello, test!" = HexPort.Test.Greeter.Port.fetch_greeting!("test")

      # Should only see one dispatch (the non-bang call), not two
      log = HexPort.Testing.get_log(HexPort.Test.Greeter)
      assert length(log) == 1
      assert [{HexPort.Test.Greeter, :fetch_greeting, ["test"], {:ok, "Hello, test!"}}] = log
    end

    test "ZeroArg auto-detects bang for get_version but not health_check" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.ZeroArg.Port)
      assert function_exported?(HexPort.Test.ZeroArg.Port, :get_version!, 0)
      refute function_exported?(HexPort.Test.ZeroArg.Port, :health_check!, 0)
    end
  end

  # ── Key helpers ───────────────────────────────────────────

  describe "key helpers" do
    test "__key__/2 generates a canonical key tuple" do
      key = HexPort.Test.Greeter.Port.__key__(:greet, "world")

      assert key == {HexPort.Test.Greeter, :greet, ["world"]}
    end

    test "__key__/2 with zero args" do
      key = HexPort.Test.ZeroArg.Port.__key__(:health_check)

      assert key == {HexPort.Test.ZeroArg, :health_check, []}
    end

    test "__key__/2 with multiple args" do
      key = HexPort.Test.MultiParam.Port.__key__(:find, "t1", :user, "u1")

      assert key == {HexPort.Test.MultiParam, :find, ["t1", :user, "u1"]}
    end

    test "__key__/2 normalizes map argument order" do
      key1 = HexPort.Test.Greeter.Port.__key__(:greet, %{b: 2, a: 1})
      key2 = HexPort.Test.Greeter.Port.__key__(:greet, %{a: 1, b: 2})

      assert key1 == key2
    end

    test "key helpers are defined for each operation" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.Greeter.Port)
      {:module, _} = Code.ensure_loaded(HexPort.Test.Counter.Port)

      # Greeter has two operations, each gets a key helper
      assert function_exported?(HexPort.Test.Greeter.Port, :__key__, 2)

      # Counter: increment(amount) → __key__/2, get_count() → __key__/1
      assert function_exported?(HexPort.Test.Counter.Port, :__key__, 2)
      assert function_exported?(HexPort.Test.Counter.Port, :__key__, 1)
    end
  end

  # ── __port_operations__/0 introspection ───────────────────

  describe "__port_operations__/0 introspection" do
    test "returns list of operation maps" do
      ops = HexPort.Test.Greeter.__port_operations__()

      assert is_list(ops)
      assert length(ops) == 2
    end

    test "each operation has required keys" do
      [op | _] = HexPort.Test.Greeter.__port_operations__()

      assert Map.has_key?(op, :name)
      assert Map.has_key?(op, :params)
      assert Map.has_key?(op, :param_types)
      assert Map.has_key?(op, :return_type)
      assert Map.has_key?(op, :bang_mode)
      assert Map.has_key?(op, :pre_dispatch)
      assert Map.has_key?(op, :arity)
    end

    test "reports correct operation names" do
      ops = HexPort.Test.Greeter.__port_operations__()
      names = Enum.map(ops, & &1.name)

      assert :greet in names
      assert :fetch_greeting in names
    end

    test "reports correct param names" do
      ops = HexPort.Test.MultiParam.__port_operations__()
      [find_op] = ops

      assert find_op.params == [:tenant, :type, :id]
      assert find_op.arity == 3
    end

    test "reports correct bang_mode for auto-detected" do
      ops = HexPort.Test.Greeter.__port_operations__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      # greet has no {:ok, T} pattern → :none
      assert op_map[:greet].bang_mode == :none
      # fetch_greeting has {:ok, T} | {:error, T} → :standard
      assert op_map[:fetch_greeting].bang_mode == :standard
    end

    test "reports correct bang_mode for explicit options" do
      ops = HexPort.Test.BangVariants.__port_operations__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      assert op_map[:auto_bang].bang_mode == :standard
      assert op_map[:forced_bang].bang_mode == :standard
      assert op_map[:suppressed_bang].bang_mode == :none
      assert {:custom, _} = op_map[:custom_bang].bang_mode
      assert op_map[:no_bang].bang_mode == :none
    end

    test "zero-arg operations report arity 0" do
      ops = HexPort.Test.ZeroArg.__port_operations__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      assert op_map[:health_check].arity == 0
      assert op_map[:health_check].params == []
    end
  end

  # ── @doc propagation ──────────────────────────────────────

  describe "@doc propagation" do
    test "user @doc is propagated to Port facade function" do
      {:docs_v1, _anno, _lang, _format, _module_doc, _meta, docs} =
        Code.fetch_docs(HexPort.Test.Documented.Port)

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
        Code.fetch_docs(HexPort.Test.Documented.Port)

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
    test "use HexPort.Contract twice in the same module compiles and works correctly" do
      modules =
        Code.compile_string("""
        defmodule HexPort.Test.DoubleUse do
          use HexPort.Contract
          use HexPort.Contract

          defport hello(name :: String.t()) :: String.t()
          defport ping() :: :pong
        end
        """)

      # Should produce just the contract module (no Behaviour submodule)
      mod_names = Enum.map(modules, fn {mod, _} -> mod end)
      assert HexPort.Test.DoubleUse in mod_names

      # Operations are correct (not duplicated)
      mod = HexPort.Test.DoubleUse
      ops = apply(mod, :__port_operations__, [])
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
        defmodule HexPort.Test.Combined do
          use HexPort.Contract
          use HexPort.Facade, contract: HexPort.Test.Combined, otp_app: :hex_port_test

          defport greet(name :: String.t()) :: String.t()
          defport ping() :: :pong
        end
        """)

      mod_names = Enum.map(modules, fn {mod, _} -> mod end)
      assert HexPort.Test.Combined in mod_names

      mod = HexPort.Test.Combined

      # Has both callbacks and facade functions
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # Has __port_operations__
      ops = apply(mod, :__port_operations__, [])
      assert length(ops) == 2

      # Facade functions exist
      assert function_exported?(mod, :greet, 1)
      assert function_exported?(mod, :ping, 0)
    end

    test "omitting contract: defaults to __MODULE__ and implies use HexPort.Contract" do
      Code.compile_string("""
      defmodule HexPort.Test.CombinedImplicit do
        use HexPort.Facade, otp_app: :hex_port_test

        defport greet(name :: String.t()) :: String.t()
        defport ping() :: :pong
      end
      """)

      mod = HexPort.Test.CombinedImplicit

      # Has callbacks (Contract was implicitly used)
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # Has __port_operations__
      ops = apply(mod, :__port_operations__, [])
      assert length(ops) == 2

      # Facade functions exist
      assert function_exported?(mod, :greet, 1)
      assert function_exported?(mod, :ping, 0)
    end

    test "facade dispatches correctly via test handler" do
      Code.compile_string("""
      defmodule HexPort.Test.CombinedDispatch do
        use HexPort.Facade, otp_app: :hex_port_test

        defport greet(name :: String.t()) :: String.t()
      end
      """)

      mod = HexPort.Test.CombinedDispatch

      HexPort.Testing.set_fn_handler(mod, fn
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
        defmodule HexPort.Test.BadUntyped do
          use HexPort.Contract
          defport bad_op(name) :: String.t()
        end
        """)
      end
    end

    test "raises on default arguments" do
      assert_raise CompileError, ~r/does not support default arguments/, fn ->
        Code.compile_string("""
        defmodule HexPort.Test.BadDefaults do
          use HexPort.Contract
          defport bad_op(name :: String.t() \\\\ "default") :: String.t()
        end
        """)
      end
    end

    test "raises when no defport declarations" do
      assert_raise CompileError, ~r/has no defport declarations/, fn ->
        Code.compile_string("""
        defmodule HexPort.Test.BadEmpty do
          use HexPort.Contract
        end
        """)
      end
    end

    test "raises on missing return type annotation" do
      assert_raise CompileError, ~r/invalid defport syntax/, fn ->
        Code.compile_string("""
        defmodule HexPort.Test.BadNoReturn do
          use HexPort.Contract
          defport bad_op(name :: String.t())
        end
        """)
      end
    end
  end

  # ── Type alias expansion ──────────────────────────────────

  describe "type alias expansion" do
    test "param_types in __port_operations__ contain fully-qualified module names" do
      ops = HexPort.Test.AliasedTypes.__port_operations__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      # list_widgets has param type Widget.t() — should be expanded to
      # HexPort.Test.Deep.Nested.Widget.t()
      [filter_type] = op_map[:list_widgets].param_types

      # The type AST should reference the fully-qualified module,
      # not the aliased short name. Convert to string for assertion.
      type_string = Macro.to_string(filter_type)
      assert type_string =~ "HexPort.Test.Deep.Nested.Widget"
      refute type_string =~ ~r/(?<!\.)Widget\.t/
    end

    test "return_type in __port_operations__ contains fully-qualified module names" do
      ops = HexPort.Test.AliasedTypes.__port_operations__()
      op_map = Map.new(ops, fn op -> {op.name, op} end)

      # get_widget returns {:ok, Widget.t()} | {:error, term()}
      return_string = Macro.to_string(op_map[:get_widget].return_type)
      assert return_string =~ "HexPort.Test.Deep.Nested.Widget"
      refute return_string =~ ~r/(?<!\.)Widget\.t/

      # list_widgets returns [Widget.t()]
      list_return_string = Macro.to_string(op_map[:list_widgets].return_type)
      assert list_return_string =~ "HexPort.Test.Deep.Nested.Widget"
    end

    test "Port module with aliased types compiles and has correct specs" do
      {:ok, specs} = Code.Typespec.fetch_specs(HexPort.Test.AliasedTypes.Port)
      spec_names = Enum.map(specs, fn {name_arity, _} -> name_arity end)

      assert {:get_widget, 1} in spec_names
      assert {:list_widgets, 1} in spec_names
      assert {:get_widget!, 1} in spec_names
    end

    test "Port facade with aliased types dispatches correctly" do
      HexPort.Testing.set_fn_handler(HexPort.Test.AliasedTypes, fn
        :get_widget, [id] -> {:ok, %HexPort.Test.Deep.Nested.Widget{id: id, label: "test"}}
        :list_widgets, [_filter] -> []
      end)

      assert {:ok, %HexPort.Test.Deep.Nested.Widget{id: "w1"}} =
               HexPort.Test.AliasedTypes.Port.get_widget("w1")

      assert [] =
               HexPort.Test.AliasedTypes.Port.list_widgets(%HexPort.Test.Deep.Nested.Widget{
                 id: "f",
                 label: "filter"
               })
    end
  end

  # ── @spec generation ──────────────────────────────────────

  describe "@spec generation" do
    test "Port functions have @spec" do
      {:ok, specs} = Code.Typespec.fetch_specs(HexPort.Test.Greeter.Port)
      spec_names = Enum.map(specs, fn {name_arity, _} -> name_arity end)

      assert {:greet, 1} in spec_names
      assert {:fetch_greeting, 1} in spec_names
    end

    test "bang variants have @spec" do
      {:ok, specs} = Code.Typespec.fetch_specs(HexPort.Test.Greeter.Port)
      spec_names = Enum.map(specs, fn {name_arity, _} -> name_arity end)

      assert {:fetch_greeting!, 1} in spec_names
    end

    test "zero-arg functions have @spec" do
      {:ok, specs} = Code.Typespec.fetch_specs(HexPort.Test.ZeroArg.Port)
      spec_names = Enum.map(specs, fn {name_arity, _} -> name_arity end)

      assert {:health_check, 0} in spec_names
      assert {:get_version, 0} in spec_names
      assert {:get_version!, 0} in spec_names
    end
  end
end
