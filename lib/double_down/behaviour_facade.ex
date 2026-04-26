defmodule DoubleDown.BehaviourFacade do
  @moduledoc """
  Generates a dispatch facade for a vanilla Elixir `@behaviour` module.

  Use this when you want DoubleDown's dispatch machinery for a behaviour
  you don't control — a third-party library behaviour, an existing
  `@behaviour` in your codebase, or any module that defines `@callback`
  declarations without using `defcallback`.

  For behaviours you *do* control, prefer `DoubleDown.ContractFacade` with
  `defcallback` — it gives you richer features (pre_dispatch transforms,
  `@doc` tag sync, combined contract + facade in one module).

  ## Usage

      defmodule MyApp.Todos do
        use DoubleDown.BehaviourFacade,
          behaviour: MyApp.Todos.Behaviour,
          otp_app: :my_app
      end

  The behaviour module must be compiled **in a prior compilation
  unit** — its `.beam` file must be on disk before the facade
  compiles. In a Mix project, this means the behaviour and facade
  must be in separate `elixirc_paths` directories (e.g. behaviour
  in `lib/` or an earlier test support directory, facade in a
  later one). Combined contract + facade in a single module is
  not supported — use `DoubleDown.ContractFacade` for that.

  ## Options

    * `:behaviour` (required) — the vanilla behaviour module to generate
      a facade for. Must define `@callback` declarations.
    * `:otp_app` (required) — the OTP application name for config-based
      dispatch. Implementations are resolved from
      `Application.get_env(otp_app, behaviour)[:impl]`.
    * `:test_dispatch?` — same as `DoubleDown.ContractFacade`. Defaults to
      `Mix.env() != :prod`.
    * `:static_dispatch?` — same as `DoubleDown.ContractFacade`. Defaults to
      `Mix.env() == :prod`.

  ## Param names

  Where `@callback` declarations use annotated types like
  `id :: String.t()`, the annotation name is used as the facade
  function's parameter name. For bare types like `String.t()`,
  parameter names are synthesized as `arg1`, `arg2`, etc.

  ## Configuration

      # config/config.exs
      config :my_app, MyApp.Todos.Behaviour, impl: MyApp.Todos.Impl

  ## Testing

      setup do
        DoubleDown.Testing.set_fun_handler(MyApp.Todos.Behaviour, fn _contract, operation, args ->
          case {operation, args} do
            {:get_item, [id]} -> {:ok, %{id: id}}
            {:list_items, []} -> []
          end
        end)
        :ok
      end

  ## Limitations vs `DoubleDown.ContractFacade`

    * No `pre_dispatch` transforms
    * No `@doc` tag sync from contract to facade
    * No combined contract + facade in one module
    * Param names are synthesized for bare (unannotated) types
    * No compile-time spec mismatch warnings

  ## See also

    * `DoubleDown.ContractFacade` — dispatch facades for `defcallback` contracts
      (richer features, recommended for new code).
    * `DoubleDown.DynamicFacade` — Mimic-style bytecode interception for any module.
  """

  alias DoubleDown.Facade.BehaviourIntrospection
  alias DoubleDown.Facade.Codegen

  @doc false
  defmacro __using__(opts) do
    behaviour =
      case Keyword.get(opts, :behaviour) do
        nil ->
          raise CompileError,
            description:
              "use DoubleDown.BehaviourFacade requires a :behaviour option. " <>
                "Example: use DoubleDown.BehaviourFacade, behaviour: MyBehaviour, otp_app: :my_app",
            file: __CALLER__.file,
            line: __CALLER__.line

        b ->
          Macro.expand(b, __CALLER__)
      end

    if behaviour == __CALLER__.module do
      raise CompileError,
        description:
          "DoubleDown.BehaviourFacade cannot be used in the same module as the behaviour " <>
            "(#{inspect(behaviour)}). The behaviour must be compiled first. " <>
            "For combined contract + facade, use DoubleDown.ContractFacade with defcallback instead.",
        file: __CALLER__.file,
        line: __CALLER__.line
    end

    otp_app = Keyword.fetch!(opts, :otp_app)

    test_dispatch? =
      Codegen.resolve_dispatch_option(
        Keyword.get(opts, :test_dispatch?),
        __CALLER__,
        Mix.env() != :prod
      )

    static_dispatch? =
      Codegen.resolve_dispatch_option(
        Keyword.get(opts, :static_dispatch?),
        __CALLER__,
        Mix.env() == :prod
      )

    # Fetch operations NOW, in the macro context. Code.ensure_compiled!
    # blocks until the behaviour module is compiled. We then read the
    # callback specs from the in-memory module — this works because the
    # macro runs during compilation, and the Elixir compiler guarantees
    # the dependency module is fully available at this point.
    operations = BehaviourIntrospection.fetch_operations!(behaviour, __CALLER__)

    static_impl =
      Codegen.resolve_static_impl(otp_app, behaviour, test_dispatch?, static_dispatch?)

    facades =
      Enum.map(
        operations,
        &Codegen.generate_facade(&1, behaviour, otp_app, test_dispatch?, static_impl)
      )

    key_helpers = Enum.map(operations, &Codegen.generate_key_helper(&1, behaviour))

    moduledoc = Codegen.generate_moduledoc(behaviour, otp_app)

    quote do
      unquote(moduledoc)
      unquote_splicing(facades)
      unquote_splicing(key_helpers)
    end
  end
end
