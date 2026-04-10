# Getting Started

[Up: README](../README.md) | [Testing >](testing.md)

## Terminology

HexPort uses terms from hexagonal architecture and testing theory.
If you're coming from Mox or standard Elixir, here's the mapping:

| HexPort term | Familiar Elixir equivalent | Nuance |
|---|---|---|
| **Contract** | Behaviour (`@callback` specs) | The abstract interface an implementation must satisfy. Same sense of "contract" in [Mocks and explicit contracts](https://dashbit.co/blog/mocks-and-explicit-contracts). HexPort generates the `@behaviour` + `@callback` from `defport` — the contract is the source of truth. |
| **Facade** | The proxy module you write by hand in Mox (`def foo(x), do: impl().foo(x)`) | The module callers use — dispatches to the configured implementation. HexPort generates this; with Mox you write it manually. |
| **Port** | (hexagonal architecture term) | A boundary through which I/O operations pass. In practice, a contract + its facade. |
| **Test double** | Mock (but broader) | Any thing that stands in for a real implementation in tests. See [test double types](https://en.wikipedia.org/wiki/Test_double#Types). |

### Test double types

HexPort supports several kinds of test double, all built on the same
handler mechanism:

| Type | What it does | HexPort API |
|---|---|---|
| **Stub** | Returns canned responses, no verification | `set_fn_handler`, `HexPort.Handler.stub` |
| **Mock** | Returns canned responses + verifies call counts/order | `HexPort.Handler.expect` + `verify!` |
| **Fake** | Working logic, simpler than production but behaviourally realistic | `set_stateful_handler`, `Repo.Test`, `Repo.InMemory` |

**Stubs** are the simplest — register a function that returns what you
need, don't bother checking how many times it was called.

**Mocks** (via `HexPort.Handler`) add expectations — the handler is
consumed in order, and `verify!` checks that all expected calls were
made. This is the Mox model.

**Fakes** are the most powerful — they have real logic. `Repo.Test`
and `Repo.InMemory` are fakes: they validate changesets, autogenerate
primary keys and timestamps, handle `Ecto.Multi`, and support
`transact(fn repo -> ... end)`. A fake can be wrong in different ways
than the real implementation, but it exercises more of your code's
behaviour than a stub or mock.

The spectrum from stub to fake is a tradeoff: stubs are easier to
write but test less; fakes test more but require more upfront work
(which HexPort provides out of the box for Repo operations).

## Defining a contract

A port contract declares the operations that cross a boundary. HexPort
uses `defport` to capture typed signatures with parameter names,
return types, and optional metadata — all available at compile time via
`__port_operations__/0`.

### Combined contract + facade (recommended)

The simplest pattern puts the contract and dispatch facade in one
module. When `HexPort.Facade` is used without a `:contract` option,
it implicitly sets up the contract in the same module:

```elixir
defmodule MyApp.Todos do
  use HexPort.Facade, otp_app: :my_app

  defport create_todo(params :: map()) ::
    {:ok, Todo.t()} | {:error, Ecto.Changeset.t()}

  defport get_todo(id :: String.t()) ::
    {:ok, Todo.t()} | {:error, :not_found}

  defport list_todos(tenant_id :: String.t()) :: [Todo.t()]
end
```

This module is now three things at once:

1. **Contract** — `@callback` declarations and `__port_operations__/0`
2. **Behaviour** — implementations use `@behaviour MyApp.Todos`
3. **Facade** — caller functions like `MyApp.Todos.create_todo/1` that
   dispatch to the configured implementation

### Separate contract and facade

When the contract lives in a different package or needs to be shared
across multiple apps with different facades, define them separately:

```elixir
defmodule MyApp.Todos.Contract do
  use HexPort.Contract

  defport create_todo(params :: map()) ::
    {:ok, Todo.t()} | {:error, Ecto.Changeset.t()}

  defport get_todo(id :: String.t()) ::
    {:ok, Todo.t()} | {:error, :not_found}
end
```

```elixir
# In a separate file (contract must compile first)
defmodule MyApp.Todos do
  use HexPort.Facade, contract: MyApp.Todos.Contract, otp_app: :my_app
end
```

This is how the built-in `HexPort.Repo.Contract` works — it defines
the contract, and your app creates a facade that binds it to your
`otp_app`. See [Repo](repo.md).

## `defport` syntax

```elixir
defport function_name(param :: type(), ...) :: return_type(), opts
```

The return type and parameter types are captured as typespecs on the
generated `@callback` declarations.

### Bang variants

`defport` auto-generates bang variants (`name!`) for operations whose
return type contains `{:ok, T} | {:error, ...}`. The bang unwraps
`{:ok, value}` and raises on `{:error, reason}`.

Control this with the `:bang` option:

| Value | Behaviour |
|-------|-----------|
| *(omitted)* | Auto-detect: generate bang if return type has `{:ok, T}` |
| `true` | Force standard `{:ok, v}` / `{:error, r}` unwrapping |
| `false` | Suppress bang generation |
| `unwrap_fn` | Generate bang using a custom unwrap function |

Example — a function that already raises, so no bang is needed:

```elixir
defport get_todo!(id :: String.t()) :: Todo.t(), bang: false
```

Example — custom unwrap for a non-standard return shape:

```elixir
defport fetch(key :: atom()) :: {:found, term()} | :missing,
  bang: fn
    {:found, v} -> v
    :missing -> raise "not found"
  end
```

### Pre-dispatch transforms

The `:pre_dispatch` option lets a contract declare a function that
transforms arguments before dispatch. The function receives `(args,
facade_module)` and returns the (possibly modified) args list. It is
spliced as AST into the generated facade function, so it runs at
call-time in the caller's process.

This is an advanced feature — most contracts don't need it. The
canonical example is `HexPort.Repo.Contract`, which uses it to wrap
1-arity transaction functions into 0-arity thunks that close over the
facade module:

```elixir
defport transact(fun_or_multi :: term(), opts :: keyword()) ::
          {:ok, term()} | {:error, term()},
        bang: false,
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

Different environments can use different implementations:

```elixir
# config/test.exs
config :my_app, MyApp.Todos, impl: MyApp.Todos.Mock
```

## Dispatch resolution

When you call `MyApp.Todos.get_todo("42")`, the facade dispatches to
the resolved implementation. The dispatch path is chosen **at compile
time** based on the `:test_dispatch?` option:

### Non-production (default)

`HexPort.Dispatch.call/4` resolves the handler in order:

1. **Test handler** — NimbleOwnership process-scoped lookup
2. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
3. **Raise** — clear error message if nothing is configured

Test handlers always take priority over config.

### Production

`HexPort.Dispatch.call_config/4` skips NimbleOwnership entirely:

1. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
2. **Raise** — clear error message if nothing is configured

No `GenServer.whereis` lookup, no NimbleOwnership code referenced in
the compiled beam — zero overhead.

### The `:test_dispatch?` option

The dispatch path is controlled by the `:test_dispatch?` option on
`use HexPort.Facade`. It accepts `true`, `false`, or a zero-arity
function returning a boolean. The function is evaluated at compile
time. The default is `fn -> Mix.env() != :prod end`:

```elixir
# Default — test dispatch in dev/test, config-only in prod
use HexPort.Facade, otp_app: :my_app

# Always config-only (e.g. a facade that never needs test doubles)
use HexPort.Facade, otp_app: :my_app, test_dispatch?: false

# Always test-aware
use HexPort.Facade, otp_app: :my_app, test_dispatch?: true

# Custom compile-time decision
use HexPort.Facade, otp_app: :my_app, test_dispatch?: fn -> Mix.env() == :test end
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
clashes with user-defined `defport key(...)` operations.

These are used with Skuld's `Port.with_test_handler/2` for effectful
testing. For plain HexPort testing, use the handler modes described
in [Testing](testing.md).

## Why `defport` instead of plain `@callback`?

HexPort could in principle generate a facade from any Elixir behaviour,
but there are practical limitations:

- **Parameter names may not be available.** A `@callback` declaration
  like `@callback get(term(), term()) :: term()` has no parameter names.
- **`Code.Typespec.fetch_callbacks/1` has limitations.** It only works
  on compiled modules with beam files on disk, not on modules being
  compiled in the same project.
- **No place for additional metadata.** `defport` supports options like
  `bang:` (bang variant generation) and `pre_dispatch:` (argument
  transforms before dispatch). Plain `@callback` has no mechanism for
  this.

`defport` captures all metadata at macro expansion time in a
structured form (`__port_operations__/0`), avoiding these limitations.

---

[Up: README](../README.md) | [Testing >](testing.md)
