defmodule HexPort.ContractTest do
  use ExUnit.Case, async: true

  # ── Behaviour generation ──────────────────────────────────

  describe "Behaviour generation" do
    test "generates a .Behaviour sub-module" do
      assert {:module, HexPort.Test.Greeter.Behaviour} =
               Code.ensure_loaded(HexPort.Test.Greeter.Behaviour)
    end

    test "Behaviour declares @callbacks for each defport" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.Greeter.Behaviour)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:greet, 1} in callback_names
      assert {:fetch_greeting, 1} in callback_names
    end

    test "Behaviour callbacks have correct arity" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.Greeter.Behaviour)
      callback_map = Map.new(callbacks, fn {name_arity, specs} -> {name_arity, specs} end)

      assert Map.has_key?(callback_map, {:greet, 1})
      assert Map.has_key?(callback_map, {:fetch_greeting, 1})
    end

    test "zero-arg operations produce arity-0 callbacks" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.ZeroArg.Behaviour)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:health_check, 0} in callback_names
      assert {:get_version, 0} in callback_names
    end

    test "multi-param operations produce correct arity callbacks" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(HexPort.Test.MultiParam.Behaviour)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> name_arity end)

      assert {:find, 3} in callback_names
    end

    test "Behaviour can be implemented (Greeter.Impl satisfies it)" do
      # The test contract Greeter.Impl uses @behaviour Greeter.Behaviour
      # and compiles without warnings — this is sufficient proof
      assert HexPort.Test.Greeter.Impl.greet("world") == "Hello, world!"
      assert HexPort.Test.Greeter.Impl.fetch_greeting("world") == {:ok, "Hello, world!"}
    end

    test "Behaviour module has @moduledoc" do
      {:docs_v1, _anno, _lang, _format, module_doc, _meta, _docs} =
        Code.fetch_docs(HexPort.Test.Greeter.Behaviour)

      assert %{"en" => doc} = module_doc
      assert doc =~ "Behaviour for"
      assert doc =~ "HexPort.Test.Greeter"
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

    test "Port module has @moduledoc" do
      {:docs_v1, _anno, _lang, _format, module_doc, _meta, _docs} =
        Code.fetch_docs(HexPort.Test.Greeter.Port)

      assert %{"en" => doc} = module_doc
      assert doc =~ "Port facade"
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
    test "key/2 generates a canonical key tuple" do
      key = HexPort.Test.Greeter.Port.key(:greet, "world")

      assert key == {HexPort.Test.Greeter, :greet, ["world"]}
    end

    test "key/2 with zero args" do
      key = HexPort.Test.ZeroArg.Port.key(:health_check)

      assert key == {HexPort.Test.ZeroArg, :health_check, []}
    end

    test "key/2 with multiple args" do
      key = HexPort.Test.MultiParam.Port.key(:find, "t1", :user, "u1")

      assert key == {HexPort.Test.MultiParam, :find, ["t1", :user, "u1"]}
    end

    test "key/2 normalizes map argument order" do
      key1 = HexPort.Test.Greeter.Port.key(:greet, %{b: 2, a: 1})
      key2 = HexPort.Test.Greeter.Port.key(:greet, %{a: 1, b: 2})

      assert key1 == key2
    end

    test "key helpers are defined for each operation" do
      {:module, _} = Code.ensure_loaded(HexPort.Test.Greeter.Port)
      {:module, _} = Code.ensure_loaded(HexPort.Test.Counter.Port)

      # Greeter has two operations, each gets a key helper
      assert function_exported?(HexPort.Test.Greeter.Port, :key, 2)

      # Counter: increment(amount) → key/2, get_count() → key/1
      assert function_exported?(HexPort.Test.Counter.Port, :key, 2)
      assert function_exported?(HexPort.Test.Counter.Port, :key, 1)
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

  # ── Compile errors ────────────────────────────────────────

  describe "compile errors" do
    test "raises on untyped parameter" do
      assert_raise CompileError, ~r/must be typed/, fn ->
        Code.compile_string("""
        defmodule HexPort.Test.BadUntyped do
          use HexPort, otp_app: :hex_port
          defport bad_op(name) :: String.t()
        end
        """)
      end
    end

    test "raises on default arguments" do
      assert_raise CompileError, ~r/does not support default arguments/, fn ->
        Code.compile_string("""
        defmodule HexPort.Test.BadDefaults do
          use HexPort, otp_app: :hex_port
          defport bad_op(name :: String.t() \\\\ "default") :: String.t()
        end
        """)
      end
    end

    test "raises when no defport declarations" do
      assert_raise CompileError, ~r/has no defport declarations/, fn ->
        Code.compile_string("""
        defmodule HexPort.Test.BadEmpty do
          use HexPort, otp_app: :hex_port
        end
        """)
      end
    end

    test "raises on missing return type annotation" do
      assert_raise CompileError, ~r/invalid defport syntax/, fn ->
        Code.compile_string("""
        defmodule HexPort.Test.BadNoReturn do
          use HexPort, otp_app: :hex_port
          defport bad_op(name :: String.t())
        end
        """)
      end
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
