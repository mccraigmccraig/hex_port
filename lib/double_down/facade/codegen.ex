defmodule DoubleDown.Facade.Codegen do
  @moduledoc false

  # Shared code generation helpers used by both `DoubleDown.ContractFacade`
  # (defcallback contracts) and `DoubleDown.ContractFacade.Behaviour`
  # (vanilla @behaviour modules).
  #
  # All public functions in this module are called at compile time
  # from `__using__` or `__before_compile__` macros and return
  # quoted AST or plain values.

  # -------------------------------------------------------------------
  # Dispatch option resolution
  # -------------------------------------------------------------------

  @doc false
  @spec resolve_dispatch_option(term(), Macro.Env.t(), boolean()) :: boolean()
  def resolve_dispatch_option(value, caller_env, default) do
    case value do
      nil ->
        default

      bool when is_boolean(bool) ->
        bool

      fun when is_function(fun, 0) ->
        fun.()

      ast ->
        # Function literal passed as an option arrives as AST in the macro.
        # Evaluate it at compile time in the caller's context.
        {fun, _binding} = Code.eval_quoted(ast, [], caller_env)
        fun.()
    end
  end

  # -------------------------------------------------------------------
  # Static impl resolution
  # -------------------------------------------------------------------

  @doc false
  @spec resolve_static_impl(atom(), atom(), boolean(), boolean()) :: module() | nil
  def resolve_static_impl(otp_app, contract, test_dispatch?, static_dispatch?) do
    if !test_dispatch? and static_dispatch? do
      case Application.get_env(otp_app, contract) do
        nil ->
          nil

        config when is_list(config) ->
          Keyword.get(config, :impl)

        impl when is_atom(impl) ->
          impl
      end
    else
      nil
    end
  end

  # -------------------------------------------------------------------
  # Code Generation: facade functions
  # -------------------------------------------------------------------

  @doc false
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def generate_facade(
        %{
          name: name,
          params: param_names,
          param_types: param_types,
          return_type: return_type,
          pre_dispatch: pre_dispatch,
          user_doc: user_doc
        } = operation,
        contract,
        otp_app,
        test_dispatch?,
        static_impl
      ) do
    # when_constraints is present for vanilla behaviour specs with `when` clauses.
    # defcallback operations don't have this field (always nil).
    when_constraints = Map.get(operation, :when_constraints)
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

    doc_ast =
      if user_doc do
        {_line, doc_content} = user_doc

        quote do
          @doc unquote(doc_content)
        end
      else
        doc_string =
          "Port operation: `#{name}/#{length(param_names)}`\n\nDispatches to the configured implementation via `DoubleDown.Contract.Dispatch`.\n"

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

    spec_ast = build_spec_ast(name, param_types, return_type, when_constraints)

    # Three dispatch paths, selected at compile time:
    #
    # 1. test_dispatch? true -> DoubleDown.Contract.Dispatch.call/4
    #    (NimbleOwnership test handlers + config fallback)
    #
    # 2. static_impl set -> apply(impl, operation, args)
    #    (direct call, zero overhead — impl resolved at compile time)
    #
    # 3. otherwise -> DoubleDown.Contract.Dispatch.call_config/4
    #    (runtime Application.get_env lookup)
    cond do
      test_dispatch? ->
        quote do
          unquote(doc_ast)
          @spec unquote(spec_ast)
          def unquote(name)(unquote_splicing(param_vars)) do
            DoubleDown.Contract.Dispatch.call(
              unquote(otp_app),
              unquote(contract),
              unquote(name),
              unquote(dispatch_args)
            )
          end
        end

      static_impl != nil && pre_dispatch == nil ->
        # Direct call + inline — zero dispatch overhead.
        # Only possible when there's no pre_dispatch transform.
        quote do
          unquote(doc_ast)
          @compile {:inline, [{unquote(name), unquote(length(param_names))}]}
          @spec unquote(spec_ast)
          def unquote(name)(unquote_splicing(param_vars)) do
            unquote(static_impl).unquote(name)(unquote_splicing(param_vars))
          end
        end

      static_impl != nil ->
        # Static impl with pre_dispatch — can't inline because args
        # are transformed at runtime.
        quote do
          unquote(doc_ast)
          @spec unquote(spec_ast)
          def unquote(name)(unquote_splicing(param_vars)) do
            apply(unquote(static_impl), unquote(name), unquote(dispatch_args))
          end
        end

      true ->
        quote do
          unquote(doc_ast)
          @spec unquote(spec_ast)
          def unquote(name)(unquote_splicing(param_vars)) do
            DoubleDown.Contract.Dispatch.call_config(
              unquote(otp_app),
              unquote(contract),
              unquote(name),
              unquote(dispatch_args)
            )
          end
        end
    end
  end

  # -------------------------------------------------------------------
  # Code Generation: key helpers
  # -------------------------------------------------------------------

  @doc false
  def generate_key_helper(%{name: name, params: param_names}, contract) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

    doc_string =
      "Build a test stub key for the `#{name}` port operation.\n"

    quote do
      @doc unquote(doc_string)
      def __key__(unquote(name), unquote_splicing(param_vars)) do
        DoubleDown.Contract.Dispatch.key(unquote(contract), unquote(name), unquote(param_vars))
      end
    end
  end

  # -------------------------------------------------------------------
  # Code Generation: @spec AST
  # -------------------------------------------------------------------

  # Build a @spec AST, optionally including `when` constraints for
  # vanilla behaviour specs with bounded type variables.
  #
  # Without constraints: name(param_types) :: return_type
  # With constraints:    name(param_types) :: return_type when var: type, ...
  defp build_spec_ast(name, param_types, return_type, nil) do
    quote do
      unquote(name)(unquote_splicing(param_types)) :: unquote(return_type)
    end
  end

  defp build_spec_ast(name, param_types, return_type, when_constraints) do
    base_spec =
      quote do
        unquote(name)(unquote_splicing(param_types)) :: unquote(return_type)
      end

    {:when, [], [base_spec, when_constraints]}
  end

  # -------------------------------------------------------------------
  # Code Generation: moduledoc
  # -------------------------------------------------------------------

  @doc false
  def generate_moduledoc(contract, otp_app, existing_moduledoc \\ nil) do
    generated =
      """
      Dispatch facade for `#{inspect(contract)}`.

      Dispatches calls to the configured implementation via
      `DoubleDown.Contract.Dispatch`. In production, resolves from application
      config (`#{inspect(otp_app)}`). In tests, resolves
      from `DoubleDown.Testing` handlers.\
      """

    combined =
      case existing_moduledoc do
        # User wrote @moduledoc false — respect it, suppress all docs
        {_, false} ->
          false

        # User provided a moduledoc — prepend it, append generated info
        {_, user_doc} when is_binary(user_doc) ->
          String.trim_trailing(user_doc) <> "\n\n---\n\n" <> generated

        # No user moduledoc — use generated only
        _ ->
          generated
      end

    quote do
      @moduledoc unquote(combined)
    end
  end
end
