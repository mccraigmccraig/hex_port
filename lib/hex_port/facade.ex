defmodule HexPort.Facade do
  @moduledoc """
  Generates a dispatch facade for a `HexPort.Contract`.

  `use HexPort.Facade` reads the contract's `__port_operations__/0` metadata
  and generates facade functions, bang variants, and key helpers that
  dispatch via `HexPort.Dispatch`.

  ## Usage

      defmodule MyApp.Todos do
        use HexPort.Facade, contract: MyApp.Todos.Contract, otp_app: :my_app
      end

  This generates:

    * Facade functions for each port operation — dispatch via config or test handler
    * Bang variants (when applicable) — unwrap `{:ok, v}` or raise on error
    * Key helpers — build canonical keys for test stub matching

  ## Options

    * `:contract` (required) — the contract module that defines the port operations
      via `use HexPort.Contract` and `defport` declarations.
    * `:otp_app` (required) — the OTP application name for config-based dispatch.
      Implementations are resolved from `Application.get_env(otp_app, contract)[:impl]`.

  ## Configuration

      # config/config.exs
      config :my_app, MyApp.Todos.Contract, impl: MyApp.Todos.Ecto

  ## Testing

      # test/test_helper.exs
      HexPort.Testing.start()

      # test/my_test.exs
      setup do
        HexPort.Testing.set_fn_handler(MyApp.Todos.Contract, fn
          :get_todo, [_tenant, id] -> {:ok, %Todo{id: id}}
          :list_todos, [_tenant] -> []
        end)
        :ok
      end

      test "gets a todo" do
        assert {:ok, %Todo{}} = MyApp.Todos.get_todo("t1", "todo-1")
      end
  """

  @doc false
  defmacro __using__(opts) do
    contract = Keyword.fetch!(opts, :contract)
    otp_app = Keyword.fetch!(opts, :otp_app)

    # Reference contract module in a way the compiler can track as a dependency.
    # This ensures the contract is compiled before this Port module.
    quote do
      require unquote(contract)
      @hex_port_contract unquote(contract)
      @hex_port_otp_app unquote(otp_app)
      @before_compile {HexPort.Facade, :__before_compile__}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    contract = Module.get_attribute(env.module, :hex_port_contract)
    otp_app = Module.get_attribute(env.module, :hex_port_otp_app)

    # The contract must already be compiled and provide __port_operations__/0
    unless Code.ensure_loaded?(contract) do
      raise CompileError,
        description:
          "Contract module #{inspect(contract)} is not loaded. " <>
            "Ensure it is compiled before #{inspect(env.module)}.",
        file: env.file,
        line: 0
    end

    unless function_exported?(contract, :__port_operations__, 0) do
      raise CompileError,
        description:
          "#{inspect(contract)} does not define __port_operations__/0. " <>
            "Did you `use HexPort.Contract` and add `defport` declarations?",
        file: env.file,
        line: 0
    end

    operations = contract.__port_operations__()

    facades = Enum.map(operations, &generate_facade(&1, contract, otp_app))

    bangs =
      operations
      |> Enum.filter(fn op -> op.bang_mode != :none end)
      |> Enum.map(&generate_bang/1)

    key_helpers = Enum.map(operations, &generate_key_helper(&1, contract))

    quote do
      @moduledoc """
      Dispatch facade for `#{inspect(unquote(contract))}`.

      Dispatches calls to the configured implementation via
      `HexPort.Dispatch`. In production, resolves from application
      config (`#{inspect(unquote(otp_app))}`). In tests, resolves
      from `HexPort.Testing` handlers.
      """

      unquote_splicing(facades)
      unquote_splicing(bangs)
      unquote_splicing(key_helpers)
    end
  end

  # -- Code Generation: Port facade functions --
  #
  # Note: operations come from __port_operations__/0 which stores
  # param_types and return_type as AST tuples (runtime data).
  # We splice them directly with unquote — Elixir treats 3-tuples as AST.

  defp generate_facade(
         %{
           name: name,
           params: param_names,
           param_types: param_types,
           return_type: return_type,
           user_doc: user_doc
         },
         contract,
         otp_app
       ) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

    doc_ast =
      if user_doc do
        {_line, doc_content} = user_doc

        quote do
          @doc unquote(doc_content)
        end
      else
        doc_string =
          "Port operation: `#{name}/#{length(param_names)}`\n\nDispatches to the configured implementation via `HexPort.Dispatch`.\n"

        quote do
          @doc unquote(doc_string)
        end
      end

    # param_types and return_type are AST tuples from __port_operations__/0.
    # We splice them directly — unquote treats 3-tuples as AST.
    #
    # For the :transact operation, we inject :repo_facade into opts so that
    # adapters can pass the Port facade module to Ecto.Multi :run callbacks.
    dispatch_args =
      if name == :transact do
        # param_vars is [fun_or_multi_var, opts_var] — inject repo_facade into opts
        [first_var | [opts_var | _]] = param_vars

        quote do
          [
            unquote(first_var),
            Keyword.put(unquote(opts_var), :repo_facade, __MODULE__)
          ]
        end
      else
        param_vars
      end

    quote do
      unquote(doc_ast)
      @spec unquote(name)(unquote_splicing(param_types)) :: unquote(return_type)
      def unquote(name)(unquote_splicing(param_vars)) do
        HexPort.Dispatch.call(
          unquote(otp_app),
          unquote(contract),
          unquote(name),
          unquote(dispatch_args)
        )
      end
    end
  end

  # -- Code Generation: Bang variants --

  defp generate_bang(%{
         name: name,
         params: param_names,
         param_types: param_types,
         return_type: return_type,
         bang_mode: bang_mode
       }) do
    bang_name = :"#{name}!"
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    unwrapped = HexPort.Contract.extract_success_type(return_type)

    {doc_string, body_ast} =
      case bang_mode do
        :standard ->
          doc =
            "Like `#{name}/#{length(param_names)}` but unwraps `{:ok, value}` or raises on error.\n"

          body =
            quote do
              case unquote({name, [], param_vars}) do
                {:ok, value} -> value
                {:error, reason} -> raise "#{unquote(name)} failed: #{inspect(reason)}"
              end
            end

          {doc, body}

        {:custom, unwrap_fn_ast} ->
          doc =
            "Like `#{name}/#{length(param_names)}` but applies a custom unwrap, then unwraps `{:ok, value}` or raises.\n"

          body =
            quote do
              result = unquote({name, [], param_vars})

              case unquote(unwrap_fn_ast).(result) do
                {:ok, value} -> value
                {:error, reason} -> raise "#{unquote(name)} failed: #{inspect(reason)}"
              end
            end

          {doc, body}
      end

    # param_types, unwrapped are AST tuples — splice directly.
    quote do
      @doc unquote(doc_string)
      @spec unquote(bang_name)(unquote_splicing(param_types)) :: unquote(unwrapped)
      def unquote(bang_name)(unquote_splicing(param_vars)) do
        unquote(body_ast)
      end
    end
  end

  # -- Code Generation: Key helpers --

  defp generate_key_helper(%{name: name, params: param_names}, contract) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

    doc_string =
      "Build a test stub key for the `#{name}` port operation.\n"

    quote do
      @doc unquote(doc_string)
      def key(unquote(name), unquote_splicing(param_vars)) do
        HexPort.Dispatch.key(unquote(contract), unquote(name), unquote(param_vars))
      end
    end
  end
end
