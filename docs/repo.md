# Repo

[< Testing](testing.md) | [Up: README](../README.md)

HexPort ships a ready-made 16-operation Ecto Repo contract with three
implementations: one for production and two test doubles. The test
doubles — especially the stateful in-memory adapter — let you test
Ecto-heavy domain logic without a database, at speeds suitable for
property-based testing.

## The contract

`HexPort.Repo.Contract` defines these operations:

| Category | Operations |
|----------|-----------|
| **Writes** | `insert/1`, `update/1`, `delete/1` |
| **Bulk** | `insert_all/3`, `update_all/3`, `delete_all/2` |
| **PK reads** | `get/2`, `get!/2` |
| **Non-PK reads** | `get_by/2`, `get_by!/2`, `one/1`, `one!/1`, `all/1`, `exists?/1`, `aggregate/3` |
| **Transactions** | `transact/2` |

Write operations return `{:ok, struct} | {:error, changeset}` and
auto-generate bang variants. Bang read variants (`get!`, `get_by!`,
`one!`) are declared as separate operations with `bang: false` —
they mirror Ecto's raise-on-not-found semantics directly.

## Creating a Repo facade

Your app creates a facade module that binds the contract to your
`otp_app`:

```elixir
defmodule MyApp.Repo do
  use HexPort.Facade, contract: HexPort.Repo.Contract, otp_app: :my_app
end
```

This generates dispatch functions (`MyApp.Repo.insert/1`,
`MyApp.Repo.get/2`, etc.) that resolve to the configured
implementation at runtime.

## Implementations

### Production — your Ecto Repo directly

Point the facade config at your Ecto Repo module. No wrapper needed —
Ecto.Repo modules already export functions at the arities the contract
calls with:

```elixir
# config/config.exs
config :my_app, HexPort.Repo.Contract, impl: MyApp.EctoRepo
```

All operations pass through to the underlying Ecto Repo with full
ACID transaction support.

### `Repo.Test` — stateless test double

A fire-and-forget adapter. Write operations apply changeset changes
and return `{:ok, struct}`, but nothing is stored. Read operations
delegate to an optional fallback function, or raise with an actionable
error message.

`Repo.Test.new/1` returns a 2-arity function handler for use with
`set_fn_handler`:

```elixir
# Writes only — reads will raise with a suggestion:
HexPort.Testing.set_fn_handler(
  HexPort.Repo.Contract,
  HexPort.Repo.Test.new()
)

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

Use `Repo.Test` when your test only needs fire-and-forget writes and
a few canned read responses. For read-after-write consistency, use
`Repo.InMemory`.

### `Repo.InMemory` — stateful test double

The main event. `Repo.InMemory` models a consistent in-memory store
with primary-key indexing, read-after-write consistency for PK lookups,
and a fallback mechanism for operations the store can't answer
authoritatively.

State is a nested map `%{schema_module => %{pk => struct}}`, stored
in NimbleOwnership via the stateful handler mechanism and updated
atomically on each dispatch.

#### The key insight

The InMemory store only contains records that have been explicitly
inserted (or seeded) during the test. It is _not_ a complete model
of the database. When a record is not found in state, InMemory cannot
know whether it "really" exists — so it must not silently return `nil`
or `[]`. Instead, it falls through to a user-supplied fallback
function, or raises a clear error.

#### Operation dispatch

| Category | Operations | Behaviour |
|----------|-----------|-----------|
| **Writes** | `insert`, `update`, `delete` | Always handled by state |
| **PK reads** | `get`, `get!` | Check state first. If found, return it. If not, fallback or error. |
| **Non-PK reads** | `get_by`, `one`, `all`, `exists?`, `aggregate`, ... | Always fallback or error |
| **Bulk** | `insert_all`, `update_all`, `delete_all` | Always fallback or error |
| **Transactions** | `transact` | Delegates to sub-operations |

#### Basic usage — writes and PK reads

If your test only needs writes and PK-based lookups, no fallback is
needed:

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

`insert` applies the changeset, auto-assigns an integer ID if the
primary key is nil, and stores the record. `get` finds it by PK.

Both test adapters validate changesets before applying them — if
`changeset.valid?` is `false`, the operation returns
`{:error, changeset}` without modifying the store, matching real
Ecto Repo behaviour.

Schemas with `timestamps()` get their `inserted_at`/`updated_at`
fields auto-populated on insert, and `updated_at` refreshed on
update. This uses Ecto's `__schema__(:autogenerate)` metadata, so
custom field names and timestamp types are handled automatically.
Explicitly set timestamps are preserved.

#### Seed data

Pre-populate the store with existing records:

```elixir
HexPort.Repo.InMemory.new(
  seed: [
    %User{id: 1, name: "Alice"},
    %Item{id: 1, sku: "widget"}
  ]
)
```

Seeded records are keyed by their schema module and primary key, and
are available for PK reads immediately.

#### Fallback function for non-PK reads

For operations the state cannot answer — anything that isn't a PK
lookup — supply a `fallback_fn`. It receives
`(operation, args, state)` where `state` is the clean store map
(internal keys stripped), so the fallback can compose canned data
with records inserted during the test:

```elixir
setup do
  alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

  state = HexPort.Repo.InMemory.new(
    seed: [alice],
    fallback_fn: fn
      :get_by, [User, [email: "alice@example.com"]], _state -> alice
      :all, [User], state -> state |> Map.get(User, %{}) |> Map.values()
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
  assert %User{name: "Alice"} = MyApp.Repo.get(User, 1)
  assert %User{name: "Alice"} = MyApp.Repo.get_by(User, email: "alice@example.com")
  assert [%User{}] = MyApp.Repo.all(User)
end
```

If the fallback function raises `FunctionClauseError` (no matching
clause), dispatch falls through to a clear error — the same behaviour
as having no fallback at all.

#### Error on unhandled operations

When an operation can't be served by either state or fallback,
`Repo.InMemory` raises `ArgumentError` with a message showing the
exact operation and suggesting how to add a fallback clause:

```
** (ArgumentError) HexPort.Repo.InMemory cannot service :get_by
   with args [User, [name: "Bob"]].

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

This fail-loud approach prevents tests from passing with silently
wrong data.

## Transactions

`transact/2` mirrors `Ecto.Repo.transact/2` — it accepts either a
function or an `Ecto.Multi` as the first argument.

### With a function

```elixir
MyApp.Repo.transact(fn ->
  {:ok, user} = MyApp.Repo.insert(user_changeset)
  {:ok, profile} = MyApp.Repo.insert(profile_changeset(user))
  {:ok, {user, profile}}
end, [])
```

The function must return `{:ok, result}` or `{:error, reason}`.
It can also accept a 1-arity form where the argument is the Repo
facade module (in test adapters) or the underlying Ecto Repo module
(in the Ecto adapter).

### With `Ecto.Multi`

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:user, user_changeset)
|> Ecto.Multi.run(:profile, fn repo, %{user: user} ->
  repo.insert(profile_changeset(user))
end)
|> MyApp.Repo.transact([])
```

On success, returns `{:ok, changes}` where `changes` is a map of
operation names to results. On failure, returns
`{:error, failed_op, failed_value, changes_so_far}`.

Multi `:run` callbacks receive the Port facade as the `repo` argument
in test adapters, or the underlying Ecto Repo module in the Ecto
adapter — so `repo.insert(cs)` dispatches correctly in both cases.

### Supported Multi operations

`insert`, `update`, `delete`, `run`, `put`, `error`, `inspect`,
`merge`, `insert_all`, `update_all`, `delete_all`.

Bulk operations (`insert_all`, `update_all`, `delete_all`) go through
the fallback function or raise in test adapters.

Both `Repo.Test` and `Repo.InMemory` share a `MultiStepper` module
that walks through Multi operations without a real database.

## Concurrency limitations of test adapters

The **Ecto adapter** provides real database transactions with full
ACID isolation — this is the production path.

The **Test** and **InMemory** adapters do **not** provide true
transaction isolation:

- `Repo.Test` calls the function directly without any locking.
- `Repo.InMemory` uses a `{:defer, fn}` mechanism to avoid
  NimbleOwnership deadlocks — the function runs outside the lock,
  and each sub-operation acquires the lock individually.

This means:

- No rollback on error — side effects from earlier operations are not
  undone.
- Concurrent writes within a transaction are not isolated from each
  other.

This is acceptable for test-only adapters where transactions are
typically exercised in serial, single-process tests. If you need true
transaction isolation, use the Ecto adapter with a real database and
Ecto's sandbox.

## Why this matters

The in-memory Repo removes the database from your test feedback loop.
Because there's no I/O, tests run at pure-function speed — fast enough
for property-based testing with StreamData or similar generators.

You get:

- **No sandbox, no migrations, no DB setup** — tests start instantly
- **Read-after-write consistency** — insert a record then `get` it back
- **Full Ecto.Multi support** — multi-step transactions work correctly
- **Property-based testing speed** — thousands of test cases per second

This is particularly valuable for domain logic that interleaves Ecto
operations. The hexagonal boundary lets you swap the real Repo for
`Repo.InMemory` and verify business rules without database overhead —
then use the Ecto adapter in integration tests for the full stack.

---

[< Testing](testing.md) | [Up: README](../README.md)
