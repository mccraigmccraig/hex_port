defmodule HexPort.Contract do
  @moduledoc """
  Macro for defining typed port contracts with `defport` declarations.

  `use HexPort.Contract` imports the `defport` macro and registers a
  `@before_compile` hook that generates:

    * `@callback` declarations on the contract module itself — the
      contract module *is* the behaviour
    * `__port_operations__/0` — introspection metadata

  Contracts are purely static interface definitions. They do **not**
  generate a dispatch facade (`.Port` module) — that is the concern of
  `HexPort.Facade`, which the consuming application uses separately to
  bind a contract to an OTP application's config.

  ## Usage

      defmodule MyApp.Todos do
        use HexPort.Contract

        defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
          {:ok, Todo.t()} | {:error, term()}

        defport list_todos(tenant_id :: String.t()) :: [Todo.t()]
      end

  This generates `@callback` declarations on `MyApp.Todos` and
  `MyApp.Todos.__port_operations__/0`.

  Implementations use `@behaviour MyApp.Todos` directly:

      defmodule MyApp.Todos.Ecto do
        @behaviour MyApp.Todos
        # ...
      end

  Compatible with `Mox.defmock(Mock, for: MyApp.Todos)`.

  To generate a dispatch facade, use `HexPort.Facade` in a separate module:

      defmodule MyApp.Todos do
        use HexPort.Facade, contract: MyApp.Todos.Contract, otp_app: :my_app
      end

  See `HexPort.Facade` for dispatch configuration and `HexPort` for an overview.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      # import is always safe to repeat and must be at module scope
      # (imports inside blocks like `unless` are scoped to that block)
      import HexPort.Contract, only: [defport: 1, defport: 2]

      # Guard the non-idempotent parts: registering the accumulator attribute
      # and the @before_compile hook. This makes `use HexPort.Contract`
      # idempotent, so a module can both `use HexPort.Contract` directly and
      # `use Skuld.Effects.Port.Contract` (which calls it internally).
      unless Module.has_attribute?(__MODULE__, :port_operations) do
        Module.register_attribute(__MODULE__, :port_operations, accumulate: true)
        @before_compile HexPort.Contract
      end
    end
  end

  @doc """
  Define a typed port operation.

  ## Syntax

      defport function_name(param :: type(), ...) :: return_type()
      defport function_name(param :: type(), ...) :: return_type(), bang: option

  ## Bang Options

    * **omitted** — auto-detect: generate bang only if return type contains `{:ok, T}`
    * **`true`** — force standard `{:ok, v}` / `{:error, r}` unwrapping
    * **`false`** — suppress bang generation
    * **`unwrap_fn`** — generate bang using custom unwrap function
  """
  defmacro defport(spec, opts \\ [])

  defmacro defport({:"::", _meta, [call_ast, return_type_ast]}, opts) do
    bang_opt = Keyword.get(opts, :bang, :auto)
    build_defport_ast(call_ast, return_type_ast, bang_opt, __CALLER__)
  end

  defmacro defport(other, _opts) do
    raise CompileError,
      description:
        "invalid defport syntax. Expected: defport name(param :: type(), ...) :: return_type()\n" <>
          "Got: #{Macro.to_string(other)}",
      file: __CALLER__.file,
      line: __CALLER__.line
  end

  # -- AST capture (at macro expansion time) --

  defp build_defport_ast(call_ast, return_type_ast, bang_opt, caller) do
    {name, params} = parse_call(call_ast, caller)

    param_names = Enum.map(params, &elem(&1, 0))

    param_types =
      Enum.map(params, fn {_name, type_ast} -> expand_type_aliases(type_ast, caller) end)

    return_type_ast = expand_type_aliases(return_type_ast, caller)

    bang_mode =
      case bang_opt do
        :auto -> if has_ok_error_pattern?(return_type_ast), do: :standard, else: :none
        true -> :standard
        false -> :none
        custom_fn_ast -> {:custom, custom_fn_ast}
      end

    op_base = %{
      name: name,
      param_names: param_names,
      param_types: param_types,
      return_type: return_type_ast,
      bang_mode: bang_mode,
      user_doc: nil
    }

    escaped_op = Macro.escape(op_base)

    quote do
      @port_operations (fn ->
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
    operations = Module.get_attribute(env.module, :port_operations) |> Enum.reverse()

    if operations == [] do
      raise CompileError,
        description:
          "#{inspect(env.module)} uses HexPort.Contract but has no defport declarations",
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
              "defport does not support default arguments (\\\\). " <>
                "Use a wrapper function instead.",
            file: caller.file,
            line: caller.line

        other ->
          raise CompileError,
            description:
              "defport parameters must be typed: `name :: type()`. Got: #{Macro.to_string(other)}",
            file: caller.file,
            line: caller.line
      end)

    {name, params}
  end

  def parse_call(other, caller) do
    raise CompileError,
      description: "invalid defport call syntax. Got: #{Macro.to_string(other)}",
      file: caller.file,
      line: caller.line
  end

  # -- Type alias expansion --
  #
  # Walk a type AST and expand any {:__aliases__, _, _} nodes using the
  # caller's alias environment.  This ensures that __port_operations__/0
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
                                bang_mode: bang_mode,
                                user_doc: user_doc
                              } ->
        quote do
          %{
            name: unquote(name),
            params: unquote(param_names),
            param_types: unquote(Macro.escape(param_types)),
            return_type: unquote(Macro.escape(return_type)),
            bang_mode: unquote(Macro.escape(bang_mode)),
            user_doc: unquote(Macro.escape(user_doc)),
            arity: unquote(length(param_names))
          }
        end
      end)

    quote do
      @doc false
      def __port_operations__ do
        unquote(op_maps)
      end
    end
  end

  # -- Type Extraction --

  @doc false
  def has_ok_error_pattern?(return_type_ast) do
    extract_from_union(return_type_ast) != nil
  end

  @doc false
  def extract_success_type(return_type_ast) do
    case extract_from_union(return_type_ast) do
      nil -> {:term, [], []}
      type -> type
    end
  end

  defp extract_from_union({:|, _, [left, right]}) do
    extract_from_ok_tuple(left) || extract_from_union(right)
  end

  defp extract_from_union(type) do
    extract_from_ok_tuple(type)
  end

  defp extract_from_ok_tuple({:{}, _, [:ok, inner_type]}), do: inner_type
  defp extract_from_ok_tuple({:ok, inner_type}), do: inner_type
  defp extract_from_ok_tuple(_), do: nil
end
