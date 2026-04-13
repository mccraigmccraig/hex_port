defmodule DoubleDown.Contract do
  @moduledoc """
  Macro for defining contract behaviours with `defcallback` declarations.

  `use DoubleDown.Contract` imports the `defcallback` macro and registers a
  `@before_compile` hook that generates:

    * `@callback` declarations on the contract module itself — the
      contract module *is* the behaviour
    * `__callbacks__/0` — introspection metadata used by `DoubleDown.Facade`
      to generate dispatch functions

  Contracts are purely static interface definitions. They do **not**
  generate a dispatch facade — that is the concern of
  `DoubleDown.Facade`, which the consuming application uses separately to
  bind a contract to an OTP application's config.

  ## Usage

      defmodule MyApp.Todos do
        use DoubleDown.Contract

        defcallback get_todo(tenant_id :: String.t(), id :: String.t()) ::
          {:ok, Todo.t()} | {:error, term()}

        defcallback list_todos(tenant_id :: String.t()) :: [Todo.t()]
      end

  This generates `@callback` declarations on `MyApp.Todos` and
  `MyApp.Todos.__callbacks__/0`.

  Implementations use `@behaviour MyApp.Todos` directly:

      defmodule MyApp.Todos.Ecto do
        @behaviour MyApp.Todos
        # ...
      end

  Compatible with `Mox.defmock(Mock, for: MyApp.Todos)`.

  To generate a dispatch facade, use `DoubleDown.Facade` in a separate module:

      defmodule MyApp.Todos do
        use DoubleDown.Facade, contract: MyApp.Todos.Contract, otp_app: :my_app
      end

  See `DoubleDown.Facade` for dispatch configuration and `DoubleDown` for an overview.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      # import is always safe to repeat and must be at module scope
      # (imports inside blocks like `unless` are scoped to that block)
      import DoubleDown.Contract, only: [defcallback: 1, defcallback: 2]

      # Guard the non-idempotent parts: registering the accumulator attribute
      # and the @before_compile hook. This makes `use DoubleDown.Contract`
      # idempotent, so a module can both `use DoubleDown.Contract` directly and
      # have it called by a wrapper macro internally.
      unless Module.has_attribute?(__MODULE__, :callback_operations) do
        Module.register_attribute(__MODULE__, :callback_operations, accumulate: true)
        @before_compile DoubleDown.Contract
      end
    end
  end

  @doc """
  Define a typed callback operation.

  `defcallback` uses a superset of the standard `@callback` syntax,
  with mandatory parameter names and optional metadata. If your
  existing `@callback` declarations include parameter names, you can
  replace `@callback` with `defcallback` and you're done:

      # Standard @callback — already valid as a defcallback
      @callback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}

      # Equivalent defcallback
      defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}

  ## Why `defcallback` instead of plain `@callback`?

    * **Parameter names are mandatory.** Plain `@callback` allows
      unnamed parameters like `@callback get(term(), term()) :: term()`.
      `defcallback` requires `name :: type()` for every parameter — these
      are used to generate meaningful `@spec` and `@doc` on the facade.

    * **Combined contract + facade.** `Code.Typespec.fetch_callbacks/1`
      only works on pre-compiled modules with beam files on disk, ruling
      out the combined contract + facade pattern entirely. `defcallback`
      captures metadata at macro expansion time via `__callbacks__/0`,
      so the contract and facade can live in the same module.

    * **LSP-friendly docs.** Plain `@callback` declarations don't
      support `@doc` — the best you can do is `#` comments that won't
      appear in hover docs. With `defcallback`, `@doc` placed above the
      declaration resolves on both the declaration and on any call site
      that goes through the facade.

    * **Additional metadata.** `defcallback` supports options like
      `pre_dispatch:` (argument transforms before dispatch). Plain
      `@callback` has no mechanism for this.

  See [Why `defcallback` instead of plain `@callback`?](docs/getting-started.md#why-defcallback-instead-of-plain-callback)
  in the Getting Started guide for the full rationale.

  ## Syntax

      defcallback function_name(param :: type(), ...) :: return_type()
      defcallback function_name(param :: type(), ...) :: return_type(), opts

  ## Options

  ### Pre-dispatch transform (`:pre_dispatch`)

    * **`:pre_dispatch`** — a function `(args, facade_module) -> args` that
      transforms the argument list before dispatch. The function receives the
      args as a list and the facade module atom, and must return the
      (possibly modified) args list. This is useful for injecting
      facade-specific context into arguments at the dispatch boundary.
      Most contracts don't need this — the canonical example is
      `DoubleDown.Repo`'s `transact` operation.

  ### Typespec mismatch severity (`:warn_on_typespec_mismatch?`)

    * **omitted / `false`** (default) — raise `CompileError` when the
      `defcallback` type spec doesn't match the production impl's `@spec`.
    * **`true`** — emit a warning instead of an error. Use this during
      migration when you know the specs differ and want to defer fixing them.

  See `DoubleDown.Contract.SpecWarnings` for details on compile-time
  spec mismatch detection.
  """
  defmacro defcallback(spec, opts \\ [])

  defmacro defcallback({:"::", _meta, [call_ast, return_type_ast]}, opts) do
    pre_dispatch_opt = Keyword.get(opts, :pre_dispatch, nil)
    warn_on_typespec_mismatch? = Keyword.get(opts, :warn_on_typespec_mismatch?, false)

    build_defcallback_ast(
      call_ast,
      return_type_ast,
      pre_dispatch_opt,
      warn_on_typespec_mismatch?,
      __CALLER__
    )
  end

  defmacro defcallback(other, _opts) do
    raise CompileError,
      description:
        "invalid defcallback syntax. Expected: defcallback name(param :: type(), ...) :: return_type()\n" <>
          "Got: #{Macro.to_string(other)}",
      file: __CALLER__.file,
      line: __CALLER__.line
  end

  # -- AST capture (at macro expansion time) --

  defp build_defcallback_ast(
         call_ast,
         return_type_ast,
         pre_dispatch_opt,
         warn_on_typespec_mismatch?,
         caller
       ) do
    {name, params} = parse_call(call_ast, caller)

    param_names = Enum.map(params, &elem(&1, 0))

    param_types =
      Enum.map(params, fn {_name, type_ast} -> expand_type_aliases(type_ast, caller) end)

    return_type_ast = expand_type_aliases(return_type_ast, caller)

    op_base = %{
      name: name,
      param_names: param_names,
      param_types: param_types,
      return_type: return_type_ast,
      pre_dispatch: pre_dispatch_opt,
      warn_on_typespec_mismatch?: warn_on_typespec_mismatch?,
      user_doc: nil
    }

    escaped_op = Macro.escape(op_base)

    quote do
      @callback_operations (fn ->
                              user_doc = Module.get_attribute(__MODULE__, :doc)
                              op = %{unquote(escaped_op) | user_doc: user_doc}
                              if user_doc, do: Module.delete_attribute(__MODULE__, :doc)
                              op
                            end).()
    end
  end

  # -- Before compile: generate @callbacks + introspection --

  @doc false
  defmacro __before_compile__(env) do
    operations = Module.get_attribute(env.module, :callback_operations) |> Enum.reverse()

    if operations == [] do
      raise CompileError,
        description:
          "#{inspect(env.module)} uses DoubleDown.Contract but has no defcallback declarations",
        file: env.file,
        line: 0
    end

    callbacks = Enum.map(operations, &generate_callback/1)
    introspection = generate_introspection(operations)

    quote do
      unquote_splicing(callbacks)
      unquote(introspection)
    end
  end

  # -- AST Parsing --

  @doc false
  def parse_call({name, _meta, nil}, _caller) when is_atom(name) do
    {name, []}
  end

  def parse_call({name, _meta, args}, caller) when is_atom(name) and is_list(args) do
    params =
      Enum.map(args, fn
        {:"::", _, [{param_name, _, _}, type_ast]} when is_atom(param_name) ->
          {param_name, type_ast}

        {:\\, _, _} ->
          raise CompileError,
            description:
              "defcallback does not support default arguments (\\\\). " <>
                "Use a wrapper function instead.",
            file: caller.file,
            line: caller.line

        other ->
          raise CompileError,
            description:
              "defcallback parameters must be typed: `name :: type()`. Got: #{Macro.to_string(other)}",
            file: caller.file,
            line: caller.line
      end)

    {name, params}
  end

  def parse_call(other, caller) do
    raise CompileError,
      description: "invalid defcallback call syntax. Got: #{Macro.to_string(other)}",
      file: caller.file,
      line: caller.line
  end

  # -- Type alias expansion --
  #
  # Walk a type AST and expand any {:__aliases__, _, _} nodes using the
  # caller's alias environment.  This ensures that __callbacks__/0
  # always stores fully-qualified module names, so @spec annotations
  # generated in Port modules (which lack the contract's aliases) resolve
  # correctly for dialyzer.

  @doc false
  def expand_type_aliases(ast, caller_env) do
    Macro.prewalk(ast, fn
      {:__aliases__, _meta, _segments} = node ->
        Macro.expand(node, caller_env)

      other ->
        other
    end)
  end

  # -- Code Generation: Behaviour callbacks --

  defp generate_callback(%{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type
       }) do
    callback_params =
      Enum.zip(param_names, param_types)
      |> Enum.map(fn {pname, ptype} ->
        {:"::", [], [{pname, [], nil}, ptype]}
      end)

    quote do
      @callback unquote(name)(unquote_splicing(callback_params)) :: unquote(return_type)
    end
  end

  # -- Code Generation: Introspection --

  defp generate_introspection(operations) do
    op_maps =
      Enum.map(operations, fn %{
                                name: name,
                                param_names: param_names,
                                param_types: param_types,
                                return_type: return_type,
                                pre_dispatch: pre_dispatch,
                                warn_on_typespec_mismatch?: warn_on_typespec_mismatch?,
                                user_doc: user_doc
                              } ->
        quote do
          %{
            name: unquote(name),
            params: unquote(param_names),
            param_types: unquote(Macro.escape(param_types)),
            return_type: unquote(Macro.escape(return_type)),
            pre_dispatch: unquote(Macro.escape(pre_dispatch)),
            warn_on_typespec_mismatch?: unquote(warn_on_typespec_mismatch?),
            user_doc: unquote(Macro.escape(user_doc)),
            arity: unquote(length(param_names))
          }
        end
      end)

    quote do
      @doc false
      def __callbacks__ do
        unquote(op_maps)
      end
    end
  end
end
