defmodule DoubleDown.Facade do
  @moduledoc """
  Generates a dispatch facade for a `DoubleDown.Contract`.

  `use DoubleDown.Facade` reads a contract's `__callbacks__/0` metadata
  and generates facade functions, bang variants, and key helpers that
  dispatch via `DoubleDown.Dispatch`.

  ## Combined contract + facade (simplest)

  When `:contract` is omitted, it defaults to `__MODULE__` and
  `use DoubleDown.Contract` is issued implicitly. This gives a single-module
  contract + facade:

      defmodule MyApp.Todos do
        use DoubleDown.Facade, otp_app: :my_app

        defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
        defcallback list_todos() :: [Todo.t()]
      end

  `MyApp.Todos` is both the contract (has `@callback`s, `__callbacks__/0`)
  and the dispatch facade.

  ## Separate contract and facade

  For cases where you want the contract in a different module:

      defmodule MyApp.Todos do
        use DoubleDown.Facade, contract: MyApp.Todos.Contract, otp_app: :my_app
      end

  ## Options

    * `:contract` — the contract module that defines port operations via
      `use DoubleDown.Contract` and `defcallback` declarations. Defaults to
      `__MODULE__` (combined contract + facade).
    * `:otp_app` (required) — the OTP application name for config-based dispatch.
      Implementations are resolved from `Application.get_env(otp_app, contract)[:impl]`.
    * `:test_dispatch?` — controls whether the generated facade includes the
      `NimbleOwnership`-based test handler resolution step. Accepts `true`,
      `false`, or a zero-arity function returning a boolean. The function is
      evaluated at compile time. Defaults to `fn -> Mix.env() != :prod end`,
      so production builds get a config-only dispatch path with zero
      `NimbleOwnership` overhead.

  ## Configuration

      # config/config.exs
      config :my_app, MyApp.Todos, impl: MyApp.Todos.Ecto

  ## Testing

      # test/test_helper.exs
      DoubleDown.Testing.start()

      # test/my_test.exs
      setup do
        DoubleDown.Testing.set_fn_handler(MyApp.Todos, fn
          :get_todo, [id] -> {:ok, %Todo{id: id}}
          :list_todos, [] -> []
        end)
        :ok
      end

      test "gets a todo" do
        assert {:ok, %Todo{}} = MyApp.Todos.get_todo("42")
      end
  """

  @doc false
  defmacro __using__(opts) do
    contract =
      case Keyword.get(opts, :contract) do
        nil -> __CALLER__.module
        c -> Macro.expand(c, __CALLER__)
      end

    otp_app = Keyword.fetch!(opts, :otp_app)

    test_dispatch? =
      case Keyword.get(opts, :test_dispatch?) do
        nil ->
          # Default: enable test dispatch in non-prod environments
          Mix.env() != :prod

        bool when is_boolean(bool) ->
          bool

        fun when is_function(fun, 0) ->
          # Direct function (e.g. from the default or programmatic use)
          fun.()

        ast ->
          # Function literal passed as an option arrives as AST in the macro.
          # Evaluate it at compile time in the caller's context.
          {fun, _binding} = Code.eval_quoted(ast, [], __CALLER__)
          fun.()
      end

    self_ref? = contract == __CALLER__.module

    if self_ref? do
      quote do
        # When the contract is this module, implicitly use DoubleDown.Contract
        # if it hasn't been used already (idempotent, so safe either way).
        use DoubleDown.Contract

        @double_down_contract unquote(contract)
        @double_down_otp_app unquote(otp_app)
        @double_down_test_dispatch unquote(test_dispatch?)
        @before_compile {DoubleDown.Facade, :__before_compile__}
      end
    else
      quote do
        require unquote(contract)
        @double_down_contract unquote(contract)
        @double_down_otp_app unquote(otp_app)
        @double_down_test_dispatch unquote(test_dispatch?)
        @before_compile {DoubleDown.Facade, :__before_compile__}
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    contract = Module.get_attribute(env.module, :double_down_contract)
    otp_app = Module.get_attribute(env.module, :double_down_otp_app)
    test_dispatch? = Module.get_attribute(env.module, :double_down_test_dispatch)

    operations = fetch_operations!(contract, env)

    facades = Enum.map(operations, &generate_facade(&1, contract, otp_app, test_dispatch?))

    bangs =
      operations
      |> Enum.filter(fn op -> op.bang_mode != :none end)
      |> Enum.map(&generate_bang/1)

    key_helpers = Enum.map(operations, &generate_key_helper(&1, contract))

    quote do
      @moduledoc """
      Dispatch facade for `#{inspect(unquote(contract))}`.

      Dispatches calls to the configured implementation via
      `DoubleDown.Dispatch`. In production, resolves from application
      config (`#{inspect(unquote(otp_app))}`). In tests, resolves
      from `DoubleDown.Testing` handlers.
      """

      unquote_splicing(facades)
      unquote_splicing(bangs)
      unquote_splicing(key_helpers)
    end
  end

  # -- Code Generation: Port facade functions --
  #
  # Note: operations come from __callbacks__/0 which stores
  # param_types and return_type as AST tuples (runtime data).
  # We splice them directly with unquote — Elixir treats 3-tuples as AST.

  defp generate_facade(
         %{
           name: name,
           params: param_names,
           param_types: param_types,
           return_type: return_type,
           pre_dispatch: pre_dispatch,
           user_doc: user_doc
         },
         contract,
         otp_app,
         test_dispatch?
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
          "Port operation: `#{name}/#{length(param_names)}`\n\nDispatches to the configured implementation via `DoubleDown.Dispatch`.\n"

        quote do
          @doc unquote(doc_string)
        end
      end

    # param_types and return_type are AST tuples from __callbacks__/0.
    # We splice them directly — unquote treats 3-tuples as AST.
    #
    # When a pre_dispatch function is declared on a defcallback, it is applied
    # to the args list before dispatch. The function receives (args, facade_module)
    # and returns the (possibly modified) args list. The pre_dispatch value
    # is AST (double-escaped through __callbacks__/0) and is spliced
    # directly into the generated function body.
    dispatch_args =
      if pre_dispatch do
        quote do
          unquote(pre_dispatch).(unquote(param_vars), __MODULE__)
        end
      else
        param_vars
      end

    # When test_dispatch? is true, use DoubleDown.Dispatch.call/4 which checks
    # NimbleOwnership for test handlers before falling back to config.
    # When false, use DoubleDown.Dispatch.call_config/4 which goes straight
    # to Application config — no NimbleOwnership overhead at all.
    dispatch_fn = if test_dispatch?, do: :call, else: :call_config

    quote do
      unquote(doc_ast)
      @spec unquote(name)(unquote_splicing(param_types)) :: unquote(return_type)
      def unquote(name)(unquote_splicing(param_vars)) do
        DoubleDown.Dispatch.unquote(dispatch_fn)(
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
    unwrapped = DoubleDown.Contract.extract_success_type(return_type)

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
      def __key__(unquote(name), unquote_splicing(param_vars)) do
        DoubleDown.Dispatch.key(unquote(contract), unquote(name), unquote(param_vars))
      end
    end
  end

  # -------------------------------------------------------------------
  # Operations fetching — supports both separate and same-module contracts
  # -------------------------------------------------------------------

  defp fetch_operations!(contract, env) do
    if contract == env.module do
      # Same-module: contract is being compiled in the same module.
      # Code.ensure_loaded? and function_exported? won't work, but
      # Module.defines? checks functions defined earlier in this
      # compilation (by a prior @before_compile hook).
      unless Module.defines?(env.module, {:__callbacks__, 0}) do
        raise CompileError,
          description:
            "#{inspect(contract)} does not define __callbacks__/0. " <>
              "Ensure `use DoubleDown.Contract` appears before `use DoubleDown.Facade` " <>
              "and add `defcallback` declarations.",
          file: env.file,
          line: 0
      end

      # We validate via Module.defines? (the output), but must read
      # the raw attribute for data since the function can't be called
      # on a module that's still being compiled.
      Module.get_attribute(env.module, :callback_operations)
      |> Enum.reverse()
      |> Enum.map(&operation_to_introspection/1)
    else
      # Separate module: contract is already compiled.
      unless Code.ensure_loaded?(contract) do
        raise CompileError,
          description:
            "Contract module #{inspect(contract)} is not loaded. " <>
              "Ensure it is compiled before #{inspect(env.module)}.",
          file: env.file,
          line: 0
      end

      unless function_exported?(contract, :__callbacks__, 0) do
        raise CompileError,
          description:
            "#{inspect(contract)} does not define __callbacks__/0. " <>
              "Did you `use DoubleDown.Contract` and add `defcallback` declarations?",
          file: env.file,
          line: 0
      end

      contract.__callbacks__()
    end
  end

  # Convert the raw @callback_operations attribute format to the public
  # __callbacks__/0 format (matching what generate_introspection
  # in DoubleDown.Contract produces).
  defp operation_to_introspection(%{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type,
         bang_mode: bang_mode,
         pre_dispatch: pre_dispatch,
         user_doc: user_doc
       }) do
    %{
      name: name,
      params: param_names,
      param_types: param_types,
      return_type: return_type,
      bang_mode: bang_mode,
      pre_dispatch: pre_dispatch,
      user_doc: user_doc,
      arity: length(param_names)
    }
  end
end
