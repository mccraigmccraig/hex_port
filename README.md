# HexPort

[![Test](https://github.com/mccraigmccraig/hex_port/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/hex_port/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/hex_port.svg)](https://hex.pm/packages/hex_port)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/hex_port/)

Hexagonal architecture ports for Elixir.

## The problem

Clean Architecture and Hexagonal Architecture tell you to put your
domain logic behind port boundaries — but Elixir doesn't give you a
standard way to define those boundaries. You end up with ad-hoc
behaviours, manual delegation modules, test doubles that aren't
process-safe, and no way to log or inspect what crossed a boundary
during a test.

## What HexPort does

HexPort gives you a single macro — `defport` — that generates typed
contracts, behaviours, and dispatch facades. In production, dispatch
reads from application config. In tests, dispatch uses process-scoped
handlers via [NimbleOwnership](https://hex.pm/packages/nimble_ownership)
(the same ownership library that [Mox](https://hex.pm/packages/mox) uses
to track mock ownership — a battle-tested, low-risk dependency),
giving you full async test isolation with zero global state.

| Feature | Description |
|---------|-------------|
| Typed contracts | `defport` declarations with full typespecs |
| Behaviour generation | Standard `@behaviour` + `@callback` — Mox-compatible |
| Separate dispatch facades | `HexPort.Facade` generates dispatch with configurable `otp_app` |
| Async-safe test doubles | Process-scoped handlers via NimbleOwnership |
| Stateful test handlers | In-memory state with PK read-after-write and fallback dispatch |
| Dispatch logging | Record every call that crosses a port boundary |
| Built-in Repo contract | 15-operation `HexPort.Repo.Contract` with test + in-memory impls |

## Two entry points

HexPort has two macros for two separate concerns:

- **`use HexPort.Contract`** — defines the contract (pure interface definition).
  Generates `@callback` declarations on the contract module and
  `X.__port_operations__/0` (introspection). The contract module *is*
  the behaviour. No `otp_app`, no dispatch facade.

- **`use HexPort.Facade, contract: X, otp_app: :my_app`** — generates the dispatch
  facade. Reads `X.__port_operations__/0` at compile time and creates facade
  functions, bang variants, and key helpers. The consuming application controls
  which `otp_app` to use.

This separation means library-provided contracts (like `HexPort.Repo.Contract`) don't
hardcode an `otp_app` — the consuming application creates a facade module
that binds the contract to its own config.

## Quick example

### Define a contract

```elixir
defmodule MyApp.Todos.Contract do
  use HexPort.Contract

  defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
    {:ok, Todo.t()} | {:error, term()}

  defport list_todos(tenant_id :: String.t()) :: [Todo.t()]

  defport create_todo!(params :: map()) :: Todo.t(), bang: false
end
```

This generates `@callback` declarations on `MyApp.Todos.Contract` (making
it a behaviour) and `MyApp.Todos.Contract.__port_operations__/0` for
introspection.

### Generate a dispatch facade

```elixir
# In a separate file (contract must compile first)
defmodule MyApp.Todos do
  use HexPort.Facade, contract: MyApp.Todos.Contract, otp_app: :my_app
end
```

This generates facade functions (`get_todo/2`, `list_todos/1`, `create_todo!/1`)
that dispatch via `HexPort.Dispatch`.

### Implement the behaviour

```elixir
defmodule MyApp.Todos.Ecto do
  @behaviour MyApp.Todos.Contract

  @impl true
  def get_todo(tenant_id, id) do
    case MyApp.Repo.get_by(Todo, tenant_id: tenant_id, id: id) do
      nil -> {:error, :not_found}
      todo -> {:ok, todo}
    end
  end

  # ...
end
```

### Configure for production

```elixir
# config/config.exs
config :my_app, MyApp.Todos.Contract, impl: MyApp.Todos.Ecto
```

### Test with process-scoped handlers

```elixir
# test/test_helper.exs
HexPort.Testing.start()

# test/my_test.exs
defmodule MyApp.TodosTest do
  use ExUnit.Case, async: true

  setup do
    HexPort.Testing.set_fn_handler(MyApp.Todos.Contract, fn
      :get_todo, [_tenant, id] -> {:ok, %Todo{id: id, title: "Test"}}
      :list_todos, [_tenant] -> [%Todo{id: "1", title: "Test"}]
      :create_todo!, [params] -> struct!(Todo, params)
    end)
    :ok
  end

  test "gets a todo" do
    assert {:ok, %Todo{id: "42"}} = MyApp.Todos.get_todo("t1", "42")
  end
end
```

## Testing features

### Function handlers

Map operations to return values with a simple function:

```elixir
HexPort.Testing.set_fn_handler(MyApp.Todos.Contract, fn
  :get_todo, [_, id] -> {:ok, %Todo{id: id}}
  :list_todos, [_] -> []
end)
```

### Stateful handlers

Maintain state across calls with atomic updates:

```elixir
HexPort.Testing.set_stateful_handler(
  MyApp.Todos.Contract,
  fn
    :create_todo!, [params], state ->
      todo = struct!(Todo, params)
      {todo, %{state | todos: [todo | state.todos]}}

    :list_todos, [_tenant], state ->
      {state.todos, state}
  end,
  %{todos: []}   # initial state
)
```

See the [InMemory adapter](#inmemory-adapter) section below for the built-in
stateful Repo implementation with its 3-stage dispatch model.

### Dispatch logging

Record and inspect every call that crosses a port boundary:

```elixir
setup do
  HexPort.Testing.enable_log(MyApp.Todos.Contract)
  HexPort.Testing.set_fn_handler(MyApp.Todos.Contract, fn
    :get_todo, [_, id] -> {:ok, %Todo{id: id}}
  end)
  :ok
end

test "logs dispatch calls" do
  MyApp.Todos.get_todo("t1", "42")

  assert [{:get_todo, ["t1", "42"], {:ok, %Todo{id: "42"}}}] =
    HexPort.Testing.get_log(MyApp.Todos.Contract)
end
```

### Async safety

All test handlers are process-scoped via NimbleOwnership. `async: true`
tests run in full isolation. `Task.async` children automatically inherit
their parent's handlers.

```elixir
HexPort.Testing.allow(MyApp.Todos.Contract, self(), some_pid)
```

## Built-in Repo contract

HexPort includes a ready-made 15-operation Ecto Repo contract covering
`insert`, `update`, `delete`, `update_all`, `delete_all`, `get`, `get!`,
`get_by`, `get_by!`, `one`, `one!`, `all`, `exists?`, `aggregate`, and
`transact`.

```elixir
# HexPort.Repo.Contract defines the contract
# Your app creates a facade module:
defmodule MyApp.Repo do
  use HexPort.Facade, contract: HexPort.Repo.Contract, otp_app: :my_app
end
```

Three implementations are provided:

| Module | Purpose |
|--------|---------|
| `HexPort.Repo.Ecto` | Delegates to your real `Ecto.Repo` |
| `HexPort.Repo.Test` | Stateless — writes apply changesets, reads use fallback or error |
| `HexPort.Repo.InMemory` | Stateful store with 3-stage read dispatch and fallback |

### Test adapter

`Repo.Test` is a stateless test double. Write operations apply changesets
and return `{:ok, struct}`, but nothing is stored. All read operations go
through an optional fallback function, or raise a clear error — the same
"fail when consistency cannot be proven" approach used by `Repo.InMemory`.

`Repo.Test.new/1` returns a 2-arity function handler for use with
`set_fn_handler`:

```elixir
# Writes only — reads will raise:
HexPort.Testing.set_fn_handler(HexPort.Repo.Contract, HexPort.Repo.Test.new())

# With fallback for reads:
HexPort.Testing.set_fn_handler(
  HexPort.Repo.Contract,
  HexPort.Repo.Test.new(
    fallback_fn: fn
      :get, [User, 1] -> %User{id: 1, name: "Alice"}
      :all, [User] -> [%User{id: 1, name: "Alice"}]
      :exists?, [User] -> true
    end
  )
)
```

Use `Repo.Test` when you only need fire-and-forget writes. For stateful
read-after-write consistency, see `Repo.InMemory`.

### InMemory adapter

`Repo.InMemory` is a stateful test double that models a consistent store.
It stores records in a nested map (`Schema => %{pk => record}`) and uses a
3-stage dispatch model for reads that reflects what the store can and cannot
answer authoritatively.

**The key insight:** the InMemory store only contains records that have been
explicitly inserted during the test. It is _not_ a complete model of the
logical store. When a record is not found in state, InMemory cannot know
whether it exists in the logical store — so it must not silently return
`nil` or `[]`. Instead, it falls through to a user-supplied fallback
function, or raises a clear error.

#### Operation categories

| Category | Operations | Behaviour |
|----------|-----------|-----------|
| **Writes** | `insert`, `update`, `delete` | Always handled by state |
| **PK reads** | `get`, `get!` | Check state first — if found, return it. If not, fallback or error |
| **Non-PK reads** | `get_by`, `get_by!`, `one`, `one!`, `all`, `exists?`, `aggregate` | Always fallback or error |
| **Bulk** | `update_all`, `delete_all` | Always fallback or error |
| **Transactions** | `transact` | Delegates to sub-operations |

#### Basic usage — writes and PK reads

If your test only needs writes and PK-based lookups, no fallback is needed:

```elixir
setup do
  HexPort.Testing.set_stateful_handler(
    HexPort.Repo.Contract,
    &HexPort.Repo.InMemory.dispatch/3,
    HexPort.Repo.InMemory.new()
  )
  :ok
end

test "insert then get by PK" do
  {:ok, user} = MyApp.Repo.insert(User.changeset(%{name: "Alice"}))
  assert ^user = MyApp.Repo.get(User, user.id)
end
```

#### Fallback function for non-PK reads

For operations the state cannot answer, supply a `fallback_fn`. It receives
`(operation, args, state)` and returns the result. The `state` argument is
the clean store map (without internal keys), so the fallback can compose
canned data with records inserted during the test. If it raises
`FunctionClauseError` (no matching clause), dispatch falls through to a
clear error:

```elixir
setup do
  alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

  state = HexPort.Repo.InMemory.new(
    seed: [alice],
    fallback_fn: fn
      :get_by, [User, [email: "alice@example.com"]], _state -> alice
      :all, [User], state -> Map.get(state, User, %{}) |> Map.values()
      :exists?, [User], _state -> true
      :aggregate, [User, :count, :id], _state -> 1
    end
  )

  HexPort.Testing.set_stateful_handler(
    HexPort.Repo.Contract,
    &HexPort.Repo.InMemory.dispatch/3,
    state
  )
  :ok
end

test "PK read comes from state, non-PK reads use fallback" do
  # PK read — served from state
  assert %User{name: "Alice"} = MyApp.Repo.get(User, 1)

  # Non-PK reads — served by fallback
  assert %User{name: "Alice"} = MyApp.Repo.get_by(User, email: "alice@example.com")
  assert [%User{}] = MyApp.Repo.all(User)
  assert MyApp.Repo.exists?(User) == true
end
```

#### Error on unhandled operations

If an operation is not handled by the state (for PK reads) or the fallback
function, InMemory raises `ArgumentError` with a message suggesting how to
add a fallback clause:

```
** (ArgumentError) HexPort.Repo.InMemory cannot service :get_by with args [User, [name: "Bob"]].

    The InMemory adapter can only answer authoritatively for:
      - Write operations (insert, update, delete)
      - PK-based reads (get, get!) when the record exists in state

    For all other operations, register a fallback function:

        HexPort.Repo.InMemory.new(
          fallback_fn: fn
            :get_by, [User, [name: "Bob"]], _state -> # your result here
          end
        )
```

### Transactions with `transact`

`transact/2` mirrors `Ecto.Repo.transact/2` — it accepts either a function
or an `Ecto.Multi` as the first argument.

**With a function:**

```elixir
MyApp.Repo.transact(fn ->
  {:ok, user} = MyApp.Repo.insert(user_changeset)
  {:ok, profile} = MyApp.Repo.insert(profile_changeset(user))
  {:ok, {user, profile}}
end, [])
```

The function must return `{:ok, result}` or `{:error, reason}`.

**With an `Ecto.Multi`:**

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:user, user_changeset)
|> Ecto.Multi.run(:profile, fn repo, %{user: user} ->
  repo.insert(profile_changeset(user))
end)
|> MyApp.Repo.transact([])
```

On success, returns `{:ok, changes}` where `changes` is a map of operation
names to results. On failure, returns `{:error, failed_op, failed_value,
changes_so_far}`.

Multi `:run` callbacks receive the Port facade as the `repo` argument in
Test and InMemory adapters (so `repo.insert(cs)` dispatches correctly),
or the underlying Ecto Repo module in the Ecto adapter.

Supported Multi operations: `insert`, `update`, `delete`, `run`, `put`,
`error`, `inspect`, `merge`, `insert_all`, `update_all`, `delete_all`.
Bulk operations (`insert_all`, `update_all`, `delete_all`) go through the
fallback function or raise in both the Test and InMemory adapters.

No `transact!` bang variant is generated (consistent with Ecto, which does
not define `Repo.transact!` either).

### Concurrency limitations of `transact` in test adapters

The **Ecto adapter** provides real database transactions with full ACID
isolation — this is the production path and works correctly under
concurrent access.

The **Test** and **InMemory** adapters do **not** provide true transaction
isolation. In the Test adapter, `transact` simply calls the function (or
steps through the Multi) without any locking. In the InMemory adapter,
`transact` uses `{:defer, fn}` to avoid NimbleOwnership deadlocks — the
function runs outside the lock, and each sub-operation acquires the lock
individually.

This means:

- There is no rollback on error — side effects from earlier operations in
  a function-based transact are not undone (Multi-based transact in test
  adapters also does not roll back successful operations on failure).
- Concurrent writes to the InMemory store within a transaction are not
  isolated from each other.

This is acceptable for test-only adapters where transactions are typically
exercised in serial, single-process tests. If your tests require true
transaction isolation, use the Ecto adapter with a real database and
Ecto's sandbox.

## Dispatch resolution

`HexPort.Dispatch.call/4` resolves handlers in order:

1. **Test handler** — NimbleOwnership process-scoped lookup (zero-cost
   in production: `GenServer.whereis` returns `nil` when the ownership
   server isn't started)
2. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
3. **Raise** — clear error message if nothing is configured

## Installation

Add `hex_port` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hex_port, "~> 0.1"}
  ]
end
```

Ecto is an optional dependency. If you want the built-in Repo contract,
add Ecto to your own deps.

## Relationship to Skuld

HexPort extracts the port system from [Skuld](https://github.com/mccraigmccraig/skuld)
(algebraic effects for Elixir) into a standalone library. You get typed
contracts, async-safe test doubles, and dispatch logging without needing
Skuld's effect system. Skuld depends on HexPort and layers effectful
dispatch on top.

## License

MIT License - see [LICENSE](LICENSE) for details.
