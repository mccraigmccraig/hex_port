# Repo

[< Testing](testing.md) | [Up: README](../README.md) | [Migration >](migration.md)

DoubleDown ships a ready-made 16-operation Ecto Repo contract with three
implementations: one for production and two test doubles. The test
doubles — especially the stateful in-memory adapter — let you test
Ecto-heavy domain logic without a database, at speeds suitable for
property-based testing.

## The contract

`DoubleDown.Repo` defines these operations:

| Category         | Operations                                                                      |
|------------------|---------------------------------------------------------------------------------|
| **Writes**       | `insert/1`, `update/1`, `delete/1`                                              |
| **Bulk**         | `insert_all/3`, `update_all/3`, `delete_all/2`                                  |
| **PK reads**     | `get/2`, `get!/2`                                                               |
| **Non-PK reads** | `get_by/2`, `get_by!/2`, `one/1`, `one!/1`, `all/1`, `exists?/1`, `aggregate/3` |
| **Transactions** | `transact/2`                                                                    |

Write operations return `{:ok, struct} | {:error, changeset}` and
auto-generate bang variants. Bang read variants (`get!`, `get_by!`,
`one!`) are declared as separate operations with `bang: false` —
they mirror Ecto's raise-on-not-found semantics directly.

## Creating a Repo facade

Your app creates a facade module that binds the contract to your
`otp_app`:

```elixir
defmodule MyApp.Repo do
  use DoubleDown.Facade, contract: DoubleDown.Repo, otp_app: :my_app
end
```

This generates dispatch functions (`MyApp.Repo.insert/1`,
`MyApp.Repo.get/2`, etc.) that dispatch to the configured
implementation.

## Implementations

### Production — your Ecto Repo directly

Point the facade config at your Ecto Repo module. No wrapper needed —
Ecto.Repo modules already export functions at the arities the contract
calls with:

```elixir
# config/config.exs
config :my_app, DoubleDown.Repo, impl: MyApp.EctoRepo
```

All operations pass through to the underlying Ecto Repo with full
ACID transaction support.

### `Repo.Test` — stateless test double

A fire-and-forget adapter. Write operations apply changeset changes
and return `{:ok, struct}`, but nothing is stored. Read operations
delegate to an optional fallback function, or raise with an actionable
error message.

`Repo.Test.new/1` returns a 2-arity function suitable for use as a
`Double.stub` fallback:

```elixir
# Writes only — reads will raise with a suggestion:
DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Test.new())

# With fallback for reads:
DoubleDown.Double.stub(
  DoubleDown.Repo,
  DoubleDown.Repo.Test.new(
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
  DoubleDown.Double.fake(
    DoubleDown.Repo,
    &DoubleDown.Repo.InMemory.dispatch/3,
    DoubleDown.Repo.InMemory.new()
  )
  :ok
end

test "insert then get by PK" do
  {:ok, user} = MyApp.Repo.insert(User.changeset(%{name: "Alice"}))
  assert ^user = MyApp.Repo.get(User, user.id)
end
```

`insert` applies the changeset, autogenerates the primary key if
nil, and stores the record. `get` finds it by PK.

Primary key autogeneration uses Ecto's schema metadata to handle
all common PK configurations:

- **`:id` type** (default `schema`) — auto-incremented integer
- **`:binary_id`** — generates a UUID string
- **Parameterized types** (`Ecto.UUID`, `Uniq.UUID`, etc.) —
  calls the type's `autogenerate` callback
- **`@primary_key false`** — no PK, works without error
- **`autogenerate: false`** — raises if no PK value is provided

Explicitly set PK values are always preserved.

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
DoubleDown.Repo.InMemory.new(
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

  state = DoubleDown.Repo.InMemory.new(
    seed: [alice],
    fallback_fn: fn
      :get_by, [User, [email: "alice@example.com"]], _state -> alice
      :all, [User], state -> state |> Map.get(User, %{}) |> Map.values()
      :exists?, [User], _state -> true
      :aggregate, [User, :count, :id], _state -> 1
    end
  )

  DoubleDown.Double.fake(
    DoubleDown.Repo,
    &DoubleDown.Repo.InMemory.dispatch/3,
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
** (ArgumentError) DoubleDown.Repo.InMemory cannot service :get_by
   with args [User, [name: "Bob"]].

    The InMemory adapter can only answer authoritatively for:
      - Write operations (insert, update, delete)
      - PK-based reads (get, get!) when the record exists in state

    For all other operations, register a fallback function:

        DoubleDown.Repo.InMemory.new(
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

Multi `:run` callbacks receive the facade module as the `repo` argument
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

## Testing failure scenarios with Double

`DoubleDown.Double` integrates with both Repo test doubles, letting you
override specific operations to simulate failures while the rest of
the Repo behaves normally.

### Error simulation with `Repo.Test`

Use a 2-arity function fallback (`Repo.Test.new/1` returns one) as
the Double's fallback stub, and add expects for the operations that
should fail:

```elixir
setup do
  DoubleDown.Repo
  |> DoubleDown.Double.stub(DoubleDown.Repo.Test.new())
  |> DoubleDown.Double.expect(:insert, fn [changeset] ->
    {:error, Ecto.Changeset.add_error(changeset, :email, "has already been taken")}
  end)
  :ok
end

test "handles duplicate email gracefully" do
  changeset = User.changeset(%User{}, %{email: "alice@example.com"})

  # First insert fails (expect fires)
  assert {:error, cs} = MyApp.Repo.insert(changeset)
  assert {"has already been taken", _} = cs.errors[:email]

  # Second insert succeeds (falls through to Repo.Test)
  assert {:ok, %User{}} = MyApp.Repo.insert(changeset)

  DoubleDown.Double.verify!()
end
```

### Error simulation with `Repo.InMemory`

Use a 3-arity stateful fallback with `Repo.InMemory` for tests that
need read-after-write consistency alongside failure simulation:

```elixir
setup do
  DoubleDown.Repo
  |> DoubleDown.Double.fake(&DoubleDown.Repo.InMemory.dispatch/3, DoubleDown.Repo.InMemory.new())
  |> DoubleDown.Double.expect(:insert, fn [changeset] ->
    {:error, Ecto.Changeset.add_error(changeset, :email, "has already been taken")}
  end)
  :ok
end

test "retries after constraint violation" do
  changeset = User.changeset(%User{}, %{email: "alice@example.com"})

  # First insert: expect fires, returns error, InMemory state unchanged
  assert {:error, _} = MyApp.Repo.insert(changeset)

  # Second insert: falls through to InMemory, writes to store
  assert {:ok, user} = MyApp.Repo.insert(changeset)

  # Read-after-write: InMemory serves from store
  assert ^user = MyApp.Repo.get(User, user.id)

  DoubleDown.Double.verify!()
end
```

### Counting calls with `:passthrough` expects

Use `:passthrough` expects to verify call counts without changing
behaviour — the call delegates to the fallback as normal, but the
expect is consumed for `verify!` counting:

```elixir
setup do
  DoubleDown.Repo
  |> DoubleDown.Double.fake(&DoubleDown.Repo.InMemory.dispatch/3, DoubleDown.Repo.InMemory.new())
  |> DoubleDown.Double.expect(:insert, :passthrough, times: 2)
  :ok
end

test "creates exactly two records" do
  # ... code under test that should insert twice ...
  DoubleDown.Double.verify!()  # fails if insert wasn't called exactly twice
end
```

You can mix `:passthrough` and function expects — for example,
"first insert succeeds through InMemory, second fails":

```elixir
DoubleDown.Repo
|> DoubleDown.Double.fake(&DoubleDown.Repo.InMemory.dispatch/3, DoubleDown.Repo.InMemory.new())
|> DoubleDown.Double.expect(:insert, :passthrough)
|> DoubleDown.Double.expect(:insert, fn [changeset] ->
  {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
end)
```

### Combining with `DoubleDown.Log`

Double and Log complement each other — Double for controlling return
values and counting calls, Log for asserting on what actually happened
including computed results:

```elixir
setup do
  DoubleDown.Repo
  |> DoubleDown.Double.fake(&DoubleDown.Repo.InMemory.dispatch/3, DoubleDown.Repo.InMemory.new())
  |> DoubleDown.Double.expect(:insert, fn [changeset] ->
    {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
  end)

  DoubleDown.Testing.enable_log(DoubleDown.Repo)
  :ok
end

test "logs the failure then the success" do
  changeset = User.changeset(%User{}, %{email: "alice@example.com"})

  assert {:error, _} = MyApp.Repo.insert(changeset)
  assert {:ok, %User{}} = MyApp.Repo.insert(changeset)

  DoubleDown.Double.verify!()

  DoubleDown.Log.match(:insert, fn
    {_, _, _, {:error, _}} -> true
  end)
  |> DoubleDown.Log.match(:insert, fn
    {_, _, _, {:ok, %User{id: id}}} when is_binary(id) -> true
  end)
  |> DoubleDown.Log.verify!(DoubleDown.Repo)
end
```

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
operations. The contract boundary lets you swap the real Repo for
`Repo.InMemory` and verify business rules without database overhead —
then use the Ecto adapter in integration tests for the full stack.

---

[< Testing](testing.md) | [Up: README](../README.md) | [Migration >](migration.md)
