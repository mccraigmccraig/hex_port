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
handlers via [NimbleOwnership](https://hex.pm/packages/nimble_ownership),
giving you full async test isolation with zero global state.

| Feature | Description |
|---------|-------------|
| Typed contracts | `defport` declarations with full typespecs |
| Behaviour generation | Standard `@behaviour` + `@callback` — Mox-compatible |
| Separate dispatch facades | `HexPort.Port` generates dispatch with configurable `otp_app` |
| Async-safe test doubles | Process-scoped handlers via NimbleOwnership |
| Stateful test handlers | In-memory state with read-after-write consistency |
| Dispatch logging | Record every call that crosses a port boundary |
| Built-in Repo contract | 15-operation Ecto Repo port with test + in-memory impls |

## Two entry points

HexPort has two macros for two separate concerns:

- **`use HexPort.Contract`** — defines the contract (pure interface definition).
  Generates `X.Behaviour` (callbacks) and `X.__port_operations__/0` (introspection).
  No `otp_app`, no dispatch facade.

- **`use HexPort.Port, contract: X, otp_app: :my_app`** — generates the dispatch
  facade. Reads `X.__port_operations__/0` at compile time and creates facade
  functions, bang variants, and key helpers. The consuming application controls
  which `otp_app` to use.

This separation means library-provided contracts (like `HexPort.Repo`) don't
hardcode an `otp_app` — the consuming application decides how dispatch works.

## Quick example

### Define a contract

```elixir
defmodule MyApp.Todos do
  use HexPort.Contract

  defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
    {:ok, Todo.t()} | {:error, term()}

  defport list_todos(tenant_id :: String.t()) :: [Todo.t()]

  defport create_todo!(params :: map()) :: Todo.t(), bang: false
end
```

This generates:

- `MyApp.Todos.Behaviour` — standard `@behaviour` with `@callback`s
- `MyApp.Todos.__port_operations__/0` — introspection for the contract

### Generate a dispatch facade

```elixir
# In a separate file (contract must compile first)
defmodule MyApp.Todos.Port do
  use HexPort.Port, contract: MyApp.Todos, otp_app: :my_app
end
```

This generates facade functions (`get_todo/2`, `list_todos/1`, `create_todo!/1`)
that dispatch via `HexPort.Dispatch`.

### Implement the behaviour

```elixir
defmodule MyApp.Todos.Ecto do
  @behaviour MyApp.Todos.Behaviour

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
config :my_app, MyApp.Todos, impl: MyApp.Todos.Ecto
```

### Test with process-scoped handlers

```elixir
# test/test_helper.exs
HexPort.Testing.start()

# test/my_test.exs
defmodule MyApp.TodosTest do
  use ExUnit.Case, async: true

  setup do
    HexPort.Testing.set_fn_handler(MyApp.Todos, fn
      :get_todo, [_tenant, id] -> {:ok, %Todo{id: id, title: "Test"}}
      :list_todos, [_tenant] -> [%Todo{id: "1", title: "Test"}]
      :create_todo!, [params] -> struct!(Todo, params)
    end)
    :ok
  end

  test "gets a todo" do
    assert {:ok, %Todo{id: "42"}} = MyApp.Todos.Port.get_todo("t1", "42")
  end
end
```

## Testing features

### Function handlers

Map operations to return values with a simple function:

```elixir
HexPort.Testing.set_fn_handler(MyApp.Todos, fn
  :get_todo, [_, id] -> {:ok, %Todo{id: id}}
  :list_todos, [_] -> []
end)
```

### Stateful handlers

Maintain state across calls for read-after-write consistency:

```elixir
HexPort.Testing.set_stateful_handler(
  MyApp.Todos,
  %{todos: []},  # initial state
  fn
    :create_todo!, [params], state ->
      todo = struct!(Todo, params)
      {todo, %{state | todos: [todo | state.todos]}}

    :list_todos, [_tenant], state ->
      {state.todos, state}
  end
)
```

### Dispatch logging

Record and inspect every call that crosses a port boundary:

```elixir
setup do
  HexPort.Testing.enable_log(MyApp.Todos)
  HexPort.Testing.set_fn_handler(MyApp.Todos, fn
    :get_todo, [_, id] -> {:ok, %Todo{id: id}}
  end)
  :ok
end

test "logs dispatch calls" do
  MyApp.Todos.Port.get_todo("t1", "42")

  assert [{:get_todo, ["t1", "42"], {:ok, %Todo{id: "42"}}}] =
    HexPort.Testing.get_log(MyApp.Todos)
end
```

### Async safety

All test handlers are process-scoped via NimbleOwnership. `async: true`
tests run in full isolation. `Task.async` children automatically inherit
their parent's handlers.

```elixir
HexPort.Testing.allow(MyApp.Todos, self(), some_pid)
```

## Built-in Repo contract

HexPort includes a ready-made 15-operation Ecto Repo contract covering
`insert`, `update`, `delete`, `update_all`, `delete_all`, `get`, `get!`,
`get_by`, `get_by!`, `one`, `one!`, `all`, `exists?`, `aggregate`, and
`transact`.

```elixir
# HexPort.Repo defines the contract (no otp_app)
# Your app creates its own Port module:
defmodule MyApp.Repo.Port do
  use HexPort.Port, contract: HexPort.Repo, otp_app: :my_app
end
```

Three implementations are provided:

| Module | Purpose |
|--------|---------|
| `HexPort.Repo.Ecto` | Delegates to your real `Ecto.Repo` |
| `HexPort.Repo.Test` | Stateless defaults (applies changesets, returns structs) |
| `HexPort.Repo.InMemory` | Stateful in-memory store with auto-increment IDs |

### Transactions with `transact`

`transact/2` mirrors `Ecto.Repo.transact/2` — it accepts either a function
or an `Ecto.Multi` as the first argument.

**With a function:**

```elixir
MyApp.Repo.Port.transact(fn ->
  {:ok, user} = MyApp.Repo.Port.insert(user_changeset)
  {:ok, profile} = MyApp.Repo.Port.insert(profile_changeset(user))
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
|> MyApp.Repo.Port.transact([])
```

On success, returns `{:ok, changes}` where `changes` is a map of operation
names to results. On failure, returns `{:error, failed_op, failed_value,
changes_so_far}`.

Multi `:run` callbacks receive the Port facade as the `repo` argument in
Test and InMemory adapters (so `repo.insert(cs)` dispatches correctly),
or the underlying Ecto Repo module in the Ecto adapter.

Supported Multi operations: `insert`, `update`, `delete`, `run`, `put`,
`error`, `inspect`, `merge`, `insert_all`, `update_all`, `delete_all`.
Bulk operations (`insert_all`, `update_all`, `delete_all`) return `{0, nil}`
in Test and InMemory adapters.

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
