# Getting Started

[Up: README](../README.md) | [Testing >](testing.md)

DoubleDown generates Mox-compatible contract behaviours and dispatch
facades from `defcallback` declarations — less boilerplate, always in
sync. The test double system goes beyond Mox with stateful fakes and
structured log assertions, making it easy to introduce boundaries
into existing code and realistic to test Ecto-heavy domain logic without
a database.

## Terminology

DoubleDown uses a few terms that are worth defining up front.
If you're coming from Mox or standard Elixir, here's the mapping:

| DoubleDown term | Familiar Elixir equivalent | Nuance |
|---|---|---|
| **Contract**    | Behaviour (`@callback` specs) | The module that defines the boundary interface. This is the key used in application config and test double setup. Can be a `defcallback` module, a vanilla `@behaviour`, or the original module in a dynamic facade. Same sense of "contract" in [Mocks and explicit contracts](https://dashbit.co/blog/mocks-and-explicit-contracts). |
| **Facade**      | The proxy module you write by hand in Mox (`def foo(x), do: impl().foo(x)`) | The module callers use — dispatches to the configured implementation. May be the same module as the contract (combined pattern, dynamic facades) or a separate module. |
| **Test double** | Mock (but broader) | Any thing that stands in for a real implementation in tests. See [test double types](https://en.wikipedia.org/wiki/Test_double#Types). |

### Test double types

DoubleDown supports several kinds of test double, all configured via
`DoubleDown.Double`:

| Type | What it does | DoubleDown API |
|---|---|---|
| **Stub** | Returns canned responses, no verification | `Double.stub` |
| **Mock** | Returns canned responses + verifies call counts/order | `Double.expect` + `verify!` |
| **Fake** | Working logic, simpler than production but behaviourally realistic | `Double.fake`, `Repo.InMemory`, `Repo.OpenInMemory` |

**Stubs** are the simplest — register a function that returns what you
need, don't bother checking how many times it was called.

**Mocks** (via `DoubleDown.Double`) add expectations — each expectation
is consumed in order, and `verify!` checks that all expected calls were
made. This is the Mox model.

**Fakes** are the most powerful — they have real logic. `Repo.InMemory`
and `Repo.OpenInMemory` are fakes: they validate changesets, autogenerate
primary keys and timestamps, handle `Ecto.Multi`, and support
`transact(fn repo -> ... end)`. A fake can be wrong in different ways
than the real implementation, but it exercises more of your code's
behaviour than a stub or mock. `Repo.Stub` is a stateless stub that
sits between plain function stubs and full fakes.

The spectrum from stub to fake is a tradeoff: stubs are easier to
write but test less; fakes test more but require more upfront work
(which DoubleDown provides out of the box for Repo operations).

## Contracts and facades

A **contract** is the module that defines the boundary — the set of
operations an implementation must provide. The **contract module**
is the key used everywhere: in application config to wire the
production implementation, and in test setup to install test doubles.

A **facade** is the module callers use — it dispatches calls to the
configured implementation. Callers never reference the implementation
directly; they call the facade, and the dispatch machinery resolves
the target.

DoubleDown supports three ways to define this pairing, each with
a different answer to "which module is the contract?":

- **`defcallback` contracts** (`DoubleDown.ContractFacade`) — richest
  option. The contract module contains `defcallback` declarations.
  In the combined (recommended) pattern, the contract and facade
  are the **same module**. In the separate pattern, the contract is
  one module and the facade is another. See
  [Why `defcallback`?](#why-defcallback-instead-of-plain-callback)
  for the rationale.

- **Vanilla behaviours** (`DoubleDown.BehaviourFacade`) — for
  existing `@behaviour` modules you don't control. The **behaviour
  module is the contract**; the facade is a separate module that
  calls `use DoubleDown.BehaviourFacade`. Config and test doubles
  reference the behaviour module.

- **Dynamic facades** (`DoubleDown.DynamicFacade`) — Mimic-style bytecode
  interception for any module, no explicit contract needed. The
  **original module is both contract and facade** —
  `DynamicFacade.setup` replaces it with a dispatch shim, and test
  doubles reference the
  original module name. See [Dynamic Facades](dynamic.md).

### Combined contract + facade (recommended)

The simplest pattern puts the contract and dispatch facade in one
module. When `DoubleDown.ContractFacade` is used without a `:contract` option,
it implicitly sets up the contract in the same module:

```elixir
defmodule MyApp.Todos do
  use DoubleDown.ContractFacade, otp_app: :my_app

  defcallback create_todo(params :: map()) ::
    {:ok, Todo.t()} | {:error, Ecto.Changeset.t()}

  defcallback get_todo(id :: String.t()) ::
    {:ok, Todo.t()} | {:error, :not_found}

  defcallback list_todos(tenant_id :: String.t()) :: [Todo.t()]
end
```

`MyApp.Todos` is both the **contract** and the **facade** —
config and test doubles both reference `MyApp.Todos`:

```elixir
# config
config :my_app, MyApp.Todos, impl: MyApp.Todos.Ecto

# test setup
DoubleDown.Double.stub(MyApp.Todos, fn :get_todo, [id] -> {:ok, %Todo{id: id}} end)
```

### Separate contract and facade

When the contract lives in a different package or needs to be shared
across multiple apps with different facades, define them separately:

```elixir
defmodule MyApp.Todos.Contract do
  use DoubleDown.Contract

  defcallback create_todo(params :: map()) ::
    {:ok, Todo.t()} | {:error, Ecto.Changeset.t()}

  defcallback get_todo(id :: String.t()) ::
    {:ok, Todo.t()} | {:error, :not_found}
end
```

```elixir
# In a separate file (contract must compile first)
defmodule MyApp.Todos do
  use DoubleDown.ContractFacade, contract: MyApp.Todos.Contract, otp_app: :my_app
end
```

Here the **contract** is `MyApp.Todos.Contract` and the **facade**
is `MyApp.Todos`. Config and test doubles reference the contract:

```elixir
# config
config :my_app, MyApp.Todos.Contract, impl: MyApp.Todos.Ecto

# test setup
DoubleDown.Double.stub(MyApp.Todos.Contract, fn :get_todo, [id] -> {:ok, %Todo{id: id}} end)
```

Callers use the facade: `MyApp.Todos.get_todo("42")`.

This is how the built-in `DoubleDown.Repo` works — it defines
the contract, and your app creates a facade that binds it to your
`otp_app`. See [Repo](repo.md).

### Facade for a vanilla behaviour

If you have an existing `@behaviour` module — from a third-party
library, a shared package, or legacy code — that you can't or don't
want to convert to `defcallback`, use `DoubleDown.BehaviourFacade`
to generate a dispatch facade directly from its `@callback`
declarations:

```elixir
defmodule MyApp.Todos do
  use DoubleDown.BehaviourFacade,
    behaviour: MyApp.Todos.Behaviour,
    otp_app: :my_app
end
```

Here the **contract** is the behaviour module
(`MyApp.Todos.Behaviour`) and the **facade** is `MyApp.Todos`.
Config and test doubles reference the behaviour module:

```elixir
# config
config :my_app, MyApp.Todos.Behaviour, impl: MyApp.Todos.Ecto

# test setup
DoubleDown.Double.stub(MyApp.Todos.Behaviour, fn
  :get_todo, [id] -> {:ok, %Todo{id: id}}
end)
```

Callers use the facade: `MyApp.Todos.get_todo("42")`.

The behaviour must be compiled before the facade (its `.beam`
file must be on disk). See `DoubleDown.BehaviourFacade` for
details and limitations compared to `defcallback`.

### Choosing a facade type

All three approaches use the same dispatch and Double
infrastructure — they coexist in the same project.

| Feature | `ContractFacade` (defcallback) | `BehaviourFacade` | `DynamicFacade` |
|---------|-------------------------------|-------------------|-----------------|
| Setup ceremony | `defcallback` + config | `use BehaviourFacade` + config | `DynamicFacade.setup(Module)` |
| Typespecs | Generated `@spec` | Generated `@spec` | None |
| LSP docs | `@doc` on facade | Generic docs | None |
| Pre-dispatch transforms | Yes | No | No |
| Combined contract + facade | Yes | No (separate modules) | N/A |
| Compile-time spec checking | Yes | No | No |
| Production dispatch | Zero-cost inlined calls | Zero-cost inlined calls | N/A (test-only) |
| Test doubles | Full Double API | Full Double API | Full Double API |
| Stateful fakes | Full support | Full support | Full support |
| Cross-contract state | Full support | Full support | Full support |
| Dispatch logging | Full support | Full support | Full support |
| async: true | Yes | Yes | Yes |

## `defcallback` syntax

`defcallback` uses the same syntax as `@callback` — if your existing
`@callback` declarations include parameter names, you can replace
`@callback` with `defcallback` and you're done:

```elixir
# Standard @callback — already works as a defcallback
@callback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, :not_found}

# Equivalent defcallback
defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, :not_found}
```

Optional metadata can be appended as keyword options:

```elixir
defcallback function_name(param :: type(), ...) :: return_type(), opts
```

The return type and parameter types are captured as typespecs on the
generated `@callback` declarations.

### Pre-dispatch transforms

The `:pre_dispatch` option lets a contract declare a function that
transforms arguments before dispatch. The function receives `(args,
facade_module)` and returns the (possibly modified) args list. It is
spliced as AST into the generated facade function, so it runs at
call-time in the caller's process.

This is an advanced feature — most contracts don't need it. The
canonical example is `DoubleDown.Repo`, which uses it to wrap
1-arity transaction functions into 0-arity thunks that close over the
facade module:

```elixir
defcallback transact(fun_or_multi :: term(), opts :: keyword()) ::
          {:ok, term()} | {:error, term()},
         pre_dispatch: fn args, facade_mod ->
          case args do
            [fun, opts] when is_function(fun, 1) ->
              [fn -> fun.(facade_mod) end, opts]

            [fun, _opts] when is_function(fun, 0) ->
              args

            _ ->
              args
          end
        end
```

This ensures that `fn repo -> repo.insert(cs) end` routes calls
through the facade dispatch chain (with logging, telemetry, etc.)
rather than bypassing it.

## Implementing a contract

Write a module that implements the behaviour. Use `@behaviour` and
`@impl true`:

```elixir
defmodule MyApp.Todos.Ecto do
  @behaviour MyApp.Todos

  @impl true
  def create_todo(params) do
    %Todo{}
    |> Todo.changeset(params)
    |> MyApp.Repo.insert()
  end

  @impl true
  def get_todo(id) do
    case MyApp.Repo.get(Todo, id) do
      nil -> {:error, :not_found}
      todo -> {:ok, todo}
    end
  end

  @impl true
  def list_todos(tenant_id) do
    MyApp.Repo.all(from t in Todo, where: t.tenant_id == ^tenant_id)
  end
end
```

The compiler will warn if your implementation is missing callbacks or
has mismatched arities.

## Configuration

Point the facade at its implementation via application config:

```elixir
# config/config.exs
config :my_app, MyApp.Todos, impl: MyApp.Todos.Ecto
```

For test environments, set `impl: nil` to enable the fail-fast
pattern — any test that forgets to set up a double gets an immediate
error instead of silently hitting a real implementation:

```elixir
# config/test.exs
config :my_app, MyApp.Todos, impl: nil
```

See [Fail-fast configuration](testing.md#fail-fast-configuration) for
details.

## Dispatch resolution

When you call `MyApp.Todos.get_todo("42")`, the facade dispatches to
the resolved implementation. The dispatch path is chosen **at compile
time** based on the `:test_dispatch?` option:

### Non-production (default)

`DoubleDown.Contract.Dispatch.call/4` resolves the implementation in order:

1. **Test double** — NimbleOwnership process-scoped lookup
2. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
3. **Raise** — clear error message if nothing is configured

Test doubles always take priority over config.

### Production (default)

Two levels of optimisation are available:

**Config dispatch** — `DoubleDown.Contract.Dispatch.call_config/4` skips
NimbleOwnership entirely but still reads `Application.get_env` at
runtime:

1. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
2. **Raise** — clear error message if nothing is configured

**Static dispatch** — when the implementation is available in config
at compile time, the facade generates inlined direct function calls
to the implementation module. No NimbleOwnership, no
`Application.get_env`, no extra stack frame — the BEAM inlines the
facade function at call sites, so `MyContract.do_thing(args)`
compiles to identical bytecode as calling the implementation directly.

Static dispatch is enabled by default in production (when
`:static_dispatch?` is true and the config is available at compile
time). If the config isn't available at compile time, it falls back
to config dispatch automatically.

### The `:test_dispatch?` and `:static_dispatch?` options

Both options accept `true`, `false`, or a zero-arity function
returning a boolean, evaluated at compile time.

`:test_dispatch?` defaults to `fn -> Mix.env() != :prod end`.
`:static_dispatch?` defaults to `fn -> Mix.env() == :prod end`.

`:test_dispatch?` takes precedence — when true, `:static_dispatch?`
is ignored.

```elixir
# Default — test dispatch in dev/test, static dispatch in prod
use DoubleDown.ContractFacade, otp_app: :my_app

# Always config-only (no test dispatch, no static dispatch)
use DoubleDown.ContractFacade, otp_app: :my_app, test_dispatch?: false, static_dispatch?: false

# Force static even in dev (e.g. for benchmarks)
use DoubleDown.ContractFacade, otp_app: :my_app, test_dispatch?: false, static_dispatch?: true
```

## Key helpers

Facade modules also generate `__key__` helper functions for building
test stub keys:

```elixir
MyApp.Todos.__key__(:get_todo, "42")
# => {MyApp.Todos, :get_todo, ["42"]}
```

The `__key__` name follows the Elixir convention for generated
introspection functions (like `__struct__`, `__schema__`), avoiding
clashes with user-defined `defcallback key(...)` operations.

## Why `defcallback` instead of plain `@callback`?

`defcallback` is recommended over plain `@callback` because it
captures richer metadata at compile time:

- **Combined contract + facade in one module.** `defcallback` works
  within the module being compiled — no need for a separate,
  pre-compiled behaviour module.
- **LSP-friendly docs.** `@doc` placed above a `defcallback` resolves
  on both the declaration and any call site through the facade.
  Hovering over `MyApp.Todos.get_todo(id)` in your editor shows the
  documentation — no manual syncing needed.
- **Additional metadata.** `defcallback` supports options like
  `pre_dispatch:` (argument transforms before dispatch). Plain
  `@callback` has no mechanism for this.
- **Compile-time spec checking.** When static dispatch is enabled,
  DoubleDown cross-checks the implementation's `@spec` against the
  contract's `defcallback` types and warns on mismatches.

For vanilla behaviours where these features aren't needed, use
`DoubleDown.BehaviourFacade` instead — see
[Facade for a vanilla behaviour](#facade-for-a-vanilla-behaviour).

---

[Up: README](../README.md) | [Testing >](testing.md)
