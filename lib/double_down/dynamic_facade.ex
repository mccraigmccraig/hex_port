defmodule DoubleDown.DynamicFacade do
  @moduledoc """
  Dynamic dispatch facades for existing modules.

  Enables Mimic-style bytecode interception — replace any module with
  a dispatch shim at test time, then use the full `DoubleDown.Double`
  API (expects, stubs, fakes, stateful responders, passthrough) without
  defining a contract or facade.

  ## Setup

  Call `setup/1` in `test/test_helper.exs` **before** `ExUnit.start()`:

      DoubleDown.DynamicFacade.setup(MyApp.EctoRepo)
      DoubleDown.DynamicFacade.setup(SomeThirdPartyModule)

      ExUnit.start()

  ## Usage in tests

      setup do
        DoubleDown.Double.fake(MyApp.EctoRepo, DoubleDown.Repo.OpenInMemory)
        :ok
      end

      test "insert then get" do
        {:ok, user} = MyApp.EctoRepo.insert(User.changeset(%{name: "Alice"}))
        assert ^user = MyApp.EctoRepo.get(User, user.id)
      end

  Tests that don't install a handler get the original module's
  behaviour — zero impact on unrelated tests.

  ## Constraints

  - Call `setup/1` before tests start (in `test_helper.exs`). Bytecode
    replacement is VM-global; calling it during async tests may cause
    flaky behaviour.
  - Cannot set up dynamic facades for DoubleDown contracts (use
    `DoubleDown.ContractFacade` instead), DoubleDown internals,
    NimbleOwnership, or Erlang/OTP modules.

  ## See also

    * `DoubleDown.ContractFacade` — dispatch facades for `defcallback` contracts
      (typed, LSP-friendly, recommended for new code).
    * `DoubleDown.BehaviourFacade` — dispatch facades for vanilla
      `@behaviour` modules (typed, but no pre_dispatch or combined
      contract + facade).
  """

  @registry_key __MODULE__

  # -- Public API --

  @doc """
  Set up a dynamic dispatch facade for a module.

  Copies the original module to a backup (`Module.__dd_original__`)
  and replaces it with a shim that dispatches through
  `DoubleDown.DynamicFacade.dispatch/3`.

  Call this in `test/test_helper.exs` **before** `ExUnit.start()`.
  Bytecode replacement is VM-global — calling during async tests may
  cause flaky behaviour.

  After setup, use the full `DoubleDown.Double` API:

      DoubleDown.Double.fake(MyModule, handler)
      DoubleDown.Double.expect(MyModule, :op, fn [args] -> result end)

  Tests that don't install a handler get the original module's
  behaviour automatically.
  """
  @spec setup(module()) :: :ok
  def setup(module) do
    if setup?(module) do
      :ok
    else
      validate_module!(module)
      do_setup(module)
      register_module(module)
      :ok
    end
  end

  @doc """
  Check whether a module has been set up for dynamic dispatch.
  """
  @spec setup?(module()) :: boolean()
  def setup?(module) do
    module in registered_modules()
  end

  @doc """
  Dispatch a call through the dynamic facade.

  Called by generated shims. Checks NimbleOwnership for a test
  handler, falls back to the original module (`Module.__dd_original__`).
  """
  @spec dispatch(module(), atom(), [term()]) :: term()
  def dispatch(module, operation, args) do
    case DoubleDown.Contract.Dispatch.resolve_test_handler(module) do
      {:ok, owner_pid, handler} ->
        result =
          DoubleDown.Contract.Dispatch.invoke_handler(handler, owner_pid, module, operation, args)

        DoubleDown.Contract.Dispatch.maybe_log(owner_pid, module, operation, args, result)
        result

      :none ->
        original = original_module(module)
        apply(original, operation, args)
    end
  end

  # -- Validation --

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_module!(module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "cannot set up dynamic facade for #{inspect(module)} — module is not loaded"
    end

    if function_exported?(module, :__callbacks__, 0) do
      raise ArgumentError,
            "cannot set up dynamic facade for #{inspect(module)} — " <>
              "it is a DoubleDown contract. Use `DoubleDown.ContractFacade` instead."
    end

    module_str = Atom.to_string(module)

    if String.starts_with?(module_str, "Elixir.DoubleDown.") and
         not String.starts_with?(module_str, "Elixir.DoubleDown.Test.") do
      raise ArgumentError,
            "cannot set up dynamic facade for #{inspect(module)} — " <>
              "it is a DoubleDown internal module"
    end

    if module == NimbleOwnership or String.starts_with?(module_str, "Elixir.NimbleOwnership.") do
      raise ArgumentError,
            "cannot set up dynamic facade for #{inspect(module)} — " <>
              "NimbleOwnership is required by the dispatch machinery"
    end

    unless String.starts_with?(module_str, "Elixir.") do
      raise ArgumentError,
            "cannot set up dynamic facade for #{inspect(module)} — " <>
              "Erlang/OTP modules cannot be shimmed"
    end

    case :code.get_object_code(module) do
      :error ->
        raise ArgumentError,
              "cannot set up dynamic facade for #{inspect(module)} — " <>
                "no beam file found (module may have been defined dynamically)"

      {^module, _binary, _path} ->
        :ok
    end
  end

  # -- Bytecode manipulation --
  #
  # Approach adapted from Mimic (https://github.com/edgurgel/mimic):
  # 1. Rename the original module by editing its abstract code and
  #    recompiling — this preserves the full original bytecode
  # 2. Create a shim module at the original name that dispatches
  #    through Dynamic.dispatch/3

  defp do_setup(module) do
    backup = original_module(module)

    # 1. Rename the original module's beam to the backup name
    rename_module(module, backup)

    # 2. Get the public function exports (from the now-backup module)
    functions = backup.module_info(:exports)
    internal = [__info__: 1, module_info: 0, module_info: 1]
    functions = Enum.reject(functions, &(&1 in internal))

    # 3. Create the dispatch shim at the original module name
    create_shim(module, functions)
  end

  defp rename_module(module, new_name) do
    beam_code =
      case :code.get_object_code(module) do
        {^module, binary, _path} -> binary
        :error -> raise "Failed to get object code for #{inspect(module)}"
      end

    {:ok, {_, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
      :beam_lib.chunks(beam_code, [:abstract_code])

    forms = rename_module_attribute(forms, new_name)

    compiler_opts =
      module.module_info(:compile)
      |> Keyword.get(:options, [])
      |> Enum.filter(&(&1 != :from_core))
      |> then(&[:return_errors, :debug_info | &1])

    binary =
      case :compile.forms(forms, compiler_opts) do
        {:ok, _module_name, binary} -> binary
        {:ok, _module_name, binary, _warnings} -> binary
      end

    {:module, ^new_name} = :code.load_binary(new_name, ~c"", binary)
  end

  defp rename_module_attribute([{:attribute, line, :module, {_, vars}} | t], new_name) do
    [{:attribute, line, :module, {new_name, vars}} | t]
  end

  defp rename_module_attribute([{:attribute, line, :module, _} | t], new_name) do
    [{:attribute, line, :module, new_name} | t]
  end

  defp rename_module_attribute([h | t], new_name) do
    [h | rename_module_attribute(t, new_name)]
  end

  defp rename_module_attribute([], _new_name), do: []

  defp create_shim(module, functions) do
    contents =
      for {name, arity} <- functions do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          def unquote(name)(unquote_splicing(args)) do
            DoubleDown.DynamicFacade.dispatch(
              unquote(module),
              unquote(name),
              unquote(args)
            )
          end
        end
      end

    prev = Code.compiler_options(ignore_module_conflict: true)

    try do
      Module.create(module, contents, Macro.Env.location(__ENV__))
    after
      Code.compiler_options(ignore_module_conflict: prev[:ignore_module_conflict])
    end
  end

  # -- Registry --

  @doc false
  def register_module(module) do
    modules = registered_modules()

    unless module in modules do
      :persistent_term.put(@registry_key, [module | modules])
    end
  end

  defp registered_modules do
    :persistent_term.get(@registry_key, [])
  end

  @doc false
  def original_module(module) do
    Module.concat(module, :__dd_original__)
  end
end
