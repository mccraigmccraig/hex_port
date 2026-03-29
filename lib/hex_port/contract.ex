defmodule HexPort.Contract do
  @moduledoc """
  Macro for defining typed port contracts with `defport` declarations.

  This module is not used directly — instead, `use HexPort` imports the
  `defport` macro and registers the `@before_compile` hook.

  Each `defport` declaration generates:

    * `@callback` on `X.Behaviour` — plain Elixir callback
    * Facade function on `X.Port` — dispatches via `HexPort.Dispatch`
    * Bang variant on `X.Port` (when applicable)
    * Key helper on `X.Port` — for test stub matching
    * `__port_operations__/0` on `X` — introspection metadata

  See `HexPort` for usage examples.
  """

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
    param_types = Enum.map(params, &elem(&1, 1))

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

  # -- Before compile: generate Behaviour + Port modules --

  @doc false
  defmacro __before_compile__(env) do
    operations = Module.get_attribute(env.module, :port_operations) |> Enum.reverse()
    otp_app = Module.get_attribute(env.module, :hex_port_otp_app)

    if operations == [] do
      raise CompileError,
        description: "#{inspect(env.module)} uses HexPort but has no defport declarations",
        file: env.file,
        line: 0
    end

    behaviour_module = Module.concat(env.module, Behaviour)
    port_module = Module.concat(env.module, Port)

    callbacks = Enum.map(operations, &generate_callback/1)
    facades = Enum.map(operations, &generate_facade(&1, otp_app))

    bangs =
      operations
      |> Enum.filter(fn op -> op.bang_mode != :none end)
      |> Enum.map(&generate_bang/1)

    key_helpers = Enum.map(operations, &generate_key_helper/1)
    introspection = generate_introspection(operations)

    contract_module = env.module

    quote do
      defmodule unquote(behaviour_module) do
        @moduledoc """
        Behaviour for `#{inspect(unquote(env.module))}`.

        Defines plain Elixir callbacks for each port operation.
        Implement this behaviour to provide a concrete adapter.

        Compatible with `Mox.defmock/2`.
        """

        unquote_splicing(callbacks)
      end

      defmodule unquote(port_module) do
        @moduledoc """
        Port facade for `#{inspect(unquote(env.module))}`.

        Dispatches calls to the configured implementation via
        `HexPort.Dispatch`. In production, resolves from application
        config. In tests, resolves from `HexPort.Testing` handlers.
        """

        @hex_port_contract unquote(contract_module)
        @hex_port_otp_app unquote(otp_app)

        unquote_splicing(facades)
        unquote_splicing(bangs)
        unquote_splicing(key_helpers)
      end

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

  # -- Code Generation: Port facade functions --

  defp generate_facade(
         %{
           name: name,
           param_names: param_names,
           param_types: param_types,
           return_type: return_type,
           user_doc: user_doc
         },
         _otp_app
       ) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    spec_params = param_types

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

    quote do
      unquote(doc_ast)
      @spec unquote(name)(unquote_splicing(spec_params)) :: unquote(return_type)
      def unquote(name)(unquote_splicing(param_vars)) do
        HexPort.Dispatch.call(
          @hex_port_otp_app,
          @hex_port_contract,
          unquote(name),
          unquote(param_vars)
        )
      end
    end
  end

  # -- Code Generation: Bang variants --

  defp generate_bang(%{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type,
         bang_mode: bang_mode
       }) do
    bang_name = :"#{name}!"
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    spec_params = param_types
    unwrapped = extract_success_type(return_type)

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

    quote do
      @doc unquote(doc_string)
      @spec unquote(bang_name)(unquote_splicing(spec_params)) :: unquote(unwrapped)
      def unquote(bang_name)(unquote_splicing(param_vars)) do
        unquote(body_ast)
      end
    end
  end

  # -- Code Generation: Key helpers --

  defp generate_key_helper(%{name: name, param_names: param_names}) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

    doc_string =
      "Build a test stub key for the `#{name}` port operation.\n"

    quote do
      @doc unquote(doc_string)
      def key(unquote(name), unquote_splicing(param_vars)) do
        HexPort.Dispatch.key(@hex_port_contract, unquote(name), unquote(param_vars))
      end
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
                                bang_mode: bang_mode
                              } ->
        quote do
          %{
            name: unquote(name),
            params: unquote(param_names),
            param_types: unquote(Macro.escape(param_types)),
            return_type: unquote(Macro.escape(return_type)),
            bang_mode: unquote(Macro.escape(bang_mode)),
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
