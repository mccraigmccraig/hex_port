# Repo

[< Process Sharing](process-sharing.md) | [Up: README](../README.md) | [Migration >](migration.md)

DoubleDown ships a ready-made Ecto Repo contract behaviour
with three test double implementations (`Repo.Test`, `Repo.InMemory`,
and `Repo.ClosedInMemory`).
In production, the dispatch facade passes through to your existing Ecto
Repo with zero overhead (via static dispatch). The test doubles are
sophisticated enough to support `Ecto.Multi` transactions and
read-after-write consistency — making it realistic to test Ecto-heavy
domain logic, including multi-step transaction code, without a database
and at speeds suitable for property-based testing.

## The contract

`DoubleDown.Repo` defines these operations:

| Category         | Operations                                                                      |
|------------------|---------------------------------------------------------------------------------|
| **Writes**       | `insert/1`, `update/1`, `delete/1`                                              |
| **Bulk**         | `insert_all/3`, `update_all/3`, `delete_all/2`                                  |
| **PK reads**     | `get/2`, `get!/2`                                                               |
| **Non-PK reads** | `get_by/2`, `get_by!/2`, `one/1`, `one!/1`, `all/1`, `exists?/1`, `aggregate/3` |
| **Transactions** | `transact/2`, `rollback/1`                                                      |

Write operations return `{:ok, struct} | {:error, changeset}`.
Raise-on-not-found variants (`get!`, `get_by!`, `one!`) are
separate contract operations mirroring Ecto's semantics.

## Creating a Repo facade

Your app creates a dispatch facade module that binds the contract to your
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

| Implementation | Type | State | Best for |
|----------------|------|-------|----------|
| **Your Ecto Repo** | Production | Real database | Production dispatch (zero-cost passthrough) |
| **`Repo.Test`** | Stateless stub | None | Fire-and-forget writes, canned read responses |
| **`Repo.InMemory`** | Stateful fake (open-world) | `%{Schema => %{pk => struct}}` | PK-based read-after-write; fallback for other reads |
| **`Repo.ClosedInMemory`** | Stateful fake (closed-world) | `%{Schema => %{pk => struct}}` | Full in-memory store; ExMachina factories; all bare-schema reads without fallback |

### Production — zero-cost passthrough to your Ecto Repo

There is no production "implementation" to write — just point the
config at your existing Ecto Repo module. Ecto.Repo modules already
export functions at the arities the contract expects, so all operations
pass straight through with full ACID transaction support:

```elixir
# config/config.exs
config :my_app, DoubleDown.Repo, impl: MyApp.EctoRepo
```

With the default `:static_dispatch?` setting, the facade resolves
`MyApp.EctoRepo` at compile time and generates inlined direct function
calls — no `Application.get_env`, no extra stack frame, the facade
compiles away entirely. `MyApp.Repo.insert(changeset)` produces
identical bytecode to `MyApp.EctoRepo.insert(changeset)`.

### `Repo.Test` — stateless test double

A fire-and-forget adapter. Write operations apply changeset changes
and return `{:ok, struct}`, but nothing is stored. Read operations
delegate to an optional fallback function, or raise with an actionable
error message.

`Repo.Test` implements `DoubleDown.Dispatch.StubHandler` and can be
used by module name with `Double.stub`:

```elixir
# Writes only — reads will raise with a suggestion:
DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Test)

# With fallback for reads:
DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Test,
  fn
    :get, [User, 1] -> %User{id: 1, name: "Alice"}
    :all, [User] -> [%User{id: 1, name: "Alice"}]
    :exists?, [User] -> true
  end
)
```

Use `Repo.Test` when your test only needs fire-and-forget writes and
a few canned read responses. For read-after-write consistency, use
`Repo.InMemory`.

### `Repo.InMemory` — stateful test double (open-world)

`Repo.InMemory` models a consistent in-memory store
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
| **get_by** | `get_by`, `get_by!` | When queryable is a bare schema and clauses include all PK fields: PK lookup in state, then fallback on miss. Otherwise: fallback or error. |
| **Non-PK reads** | `one`, `all`, `exists?`, `aggregate`, ... | Always fallback or error |
| **Bulk** | `insert_all`, `update_all`, `delete_all` | Always fallback or error |
| **Transactions** | `transact`, `rollback` | Delegates to sub-operations; rollback throws to unwind |

#### Basic usage — writes and PK reads

If your test only needs writes and PK-based lookups, no fallback is
needed:

```elixir
setup do
  DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)
  :ok
end

test "insert then get by PK" do
  {:ok, user} = MyApp.Repo.insert(User.changeset(%{name: "Alice"}))
  assert ^user = MyApp.Repo.get(User, user.id)
end

test "insert then get_by with PK in clauses" do
  {:ok, user} = MyApp.Repo.insert(User.changeset(%{name: "Alice"}))
  assert ^user = MyApp.Repo.get_by(User, id: user.id)
  assert ^user = MyApp.Repo.get_by(User, id: user.id, name: "Alice")
end
```

`insert` applies the changeset, autogenerates the primary key if
nil, and stores the record. `get` finds it by PK. `get_by` also
uses PK lookup when the clauses include all primary key fields —
any additional clauses are verified against the found record.

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

Pre-populate the store with existing records by passing them as the
third argument to `Double.fake`:

```elixir
DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory,
  [%User{id: 1, name: "Alice"}, %Item{id: 1, sku: "widget"}])
```

Seeded records are keyed by their schema module and primary key, and
are available for PK reads immediately.

#### Fallback function for non-PK reads

For operations the state cannot answer — reads where the clauses
don't include the primary key, `Ecto.Query`-based reads, and
operations like `one`, `all`, `exists?`, `aggregate` — supply a
`fallback_fn`. The fallback is also used for `get_by` when the PK
is in the clauses but the record is not found in state (absence is
not authoritative — the store is incomplete).

The fallback receives `(operation, args, state)` where `state` is
the clean store map (internal keys stripped), so it can compose
canned data with records inserted during the test:

```elixir
setup do
  alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

  DoubleDown.Double.fake(
    DoubleDown.Repo,
    DoubleDown.Repo.InMemory,
    [alice],
    fallback_fn: fn
      :get_by, [User, [email: "alice@example.com"]], _state -> alice
      :all, [User], state -> state |> Map.get(User, %{}) |> Map.values()
      :exists?, [User], _state -> true
      :aggregate, [User, :count, :id], _state -> 1
    end
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

### `Repo.ClosedInMemory` — stateful test double (closed-world)

`Repo.ClosedInMemory` uses **closed-world semantics**: the state is
the complete truth. If a record isn't in the state, it doesn't
exist. This makes the adapter authoritative for all bare schema
operations without needing a fallback — the fallback becomes the
escape hatch for `Ecto.Query` queryables, not the default path:

| Category | Operations | Behaviour |
|----------|-----------|-----------|
| **Writes** | `insert`, `update`, `delete` | Same as InMemory |
| **PK reads** | `get`, `get!` | Return `nil` / raise on miss (no fallback) |
| **Clause reads** | `get_by`, `get_by!` | Scan and filter all records |
| **Collection reads** | `all`, `one`/`one!`, `exists?` | Scan all records of schema |
| **Aggregates** | `aggregate` | Compute from records in state |
| **Bulk writes** | `insert_all`, `delete_all`, `update_all` (`set:`) | Modify state directly |
| **Transactions** | `transact`, `rollback` | Same as InMemory |
| **Ecto.Query** | Any operation with `Ecto.Query` queryable | Fallback or error |

Use `ClosedInMemory` when the state is the full picture — typically
when using factories (e.g. ExMachina) to build test data:

```elixir
setup do
  DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.ClosedInMemory)

  # Factory-inserted records are the complete store
  insert(:user, name: "Alice", email: "alice@example.com")
  insert(:user, name: "Bob", email: "bob@example.com")
  :ok
end

test "all users" do
  assert [_, _] = MyApp.Repo.all(User)
end

test "find by email" do
  assert %User{name: "Alice"} =
    MyApp.Repo.get_by(User, email: "alice@example.com")
end

test "count users" do
  assert 2 = MyApp.Repo.aggregate(User, :count, :id)
end
```

The fallback function is still available as an escape hatch for
`Ecto.Query` queryables that cannot be evaluated in-memory:

```elixir
DoubleDown.Double.fake(
  DoubleDown.Repo,
  DoubleDown.Repo.ClosedInMemory,
  [],
  fallback_fn: fn
    :all, [%Ecto.Query{}], _state -> []
  end
)
```

Use `InMemory` (open-world) when the state is partial and missing
records should fall through to a fallback. Use `ClosedInMemory`
(closed-world) when the state is the complete truth.

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
Alternatively, call `repo.rollback(value)` to abort the transaction
— `transact` will return `{:error, value}`.

The function can also accept a 1-arity form where the argument is
the Repo facade module (in test adapters) or the underlying Ecto
Repo module (in the Ecto adapter).

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

### Rollback

`rollback/1` mirrors `Ecto.Repo.rollback/1` — it aborts the current
transaction and causes `transact` to return `{:error, value}`:

```elixir
MyApp.Repo.transact(fn repo ->
  {:ok, user} = repo.insert(user_changeset)

  if some_condition do
    repo.rollback(:constraint_violated)
  end

  {:ok, user}
end, [])
# Returns {:error, :constraint_violated} if rollback was called
```

Internally, `rollback` throws `{:rollback, value}`, which is caught
by `transact`. This matches the Ecto.Repo pattern. Code after
`rollback` is not executed.

**Limitation:** In the test adapters, `rollback` does not undo state
mutations from earlier operations within the transaction. If `insert`
was called before `rollback`, the record remains in the InMemory
store. This is a consequence of the deferred execution model — each
sub-operation runs independently outside the lock. For tests that
need true rollback semantics, use the Ecto adapter with a real
database.

## Concurrency limitations of test adapters

The **Ecto adapter** provides real database transactions with full
ACID isolation — this is the production path.

The **Test** and **InMemory** adapters do **not** provide true
transaction isolation:

- `Repo.Test` calls the function directly without any locking.
- `Repo.InMemory` uses `%DoubleDown.Dispatch.Defer{}` to run the transaction
  function outside the NimbleOwnership lock — each sub-operation
  acquires the lock individually.

This means:

- `rollback/1` is supported as an API (returns `{:error, value}` from
  `transact`), but does not undo state mutations from earlier operations.
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
  |> DoubleDown.Double.stub(DoubleDown.Repo.Test)
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
  |> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
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
  |> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
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
|> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
|> DoubleDown.Double.expect(:insert, :passthrough)
|> DoubleDown.Double.expect(:insert, fn [changeset] ->
  {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
end)
```

### Stateful expects and stubs with `Repo.InMemory`

Expects and per-operation stubs can be 2-arity or 3-arity to read
and update the InMemory store directly. The state passed to the
responder is the InMemory store (`%{Schema => %{pk => record}}`):

```elixir
# 2-arity expect: reject duplicate emails, otherwise passthrough
DoubleDown.Repo
|> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
|> DoubleDown.Double.stub(:insert, fn [changeset], state ->
  existing_emails =
    state
    |> Map.get(User, %{})
    |> Map.values()
    |> Enum.map(& &1.email)

  if Ecto.Changeset.get_field(changeset, :email) in existing_emails do
    {{:error, Ecto.Changeset.add_error(changeset, :email, "taken")}, state}
  else
    # No duplicate — let InMemory handle it normally
    DoubleDown.Double.passthrough()
  end
end)
```

This is more powerful than 1-arity expects because:

- The responder can **inspect the current store** to make decisions
  (e.g. check for duplicates, verify foreign keys exist)
- The responder can **update the store** directly when needed
- `Double.passthrough()` delegates to InMemory when the responder
  doesn't want to handle the call — no need to duplicate InMemory's
  insert logic
- As a **stub**, it applies to every call indefinitely — no need to
  guess `times: N`

See [Stateful expect responders](testing.md#stateful-expect-responders)
and [Stateful per-operation stubs](testing.md#stateful-per-operation-stubs)
in the Testing guide for the full API.

### Combining with `DoubleDown.Log`

Double and Log complement each other — Double for controlling return
values and counting calls, Log for asserting on what actually happened
including computed results:

```elixir
setup do
  DoubleDown.Repo
  |> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
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

## Cross-contract state access

The "two-contract" pattern separates write operations (through the
`DoubleDown.Repo` contract) from domain-specific query operations
(through a separate contract). In production, both hit the same
database. In tests, the Repo uses `Repo.InMemory`, and the query
contract needs to see what Repo has written.

4-arity stateful handlers enable this by providing a read-only
snapshot of all contract states. The Queries handler can look up the
Repo's InMemory store and answer queries against it.

### Example: Queries handler reading Repo state

```elixir
# Define a domain-specific query contract
defmodule MyApp.UserQueries do
  use DoubleDown.Contract

  defcallback active_users() :: [User.t()]
  defcallback user_by_email(email :: String.t()) :: User.t() | nil
end
```

```elixir
# In tests, set up Repo with InMemory and Queries with a 4-arity fake
setup do
  # Repo uses InMemory — writes land here
  DoubleDown.Repo
  |> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)

  # Queries uses a 4-arity fake that reads Repo's InMemory state
  MyApp.UserQueries
  |> DoubleDown.Double.fake(
    fn operation, args, state, all_states ->
      # Extract Repo's InMemory store from the global snapshot
      repo_state = Map.get(all_states, DoubleDown.Repo, %{})
      users = repo_state |> Map.get(User, %{}) |> Map.values()

      result =
        case {operation, args} do
          {:active_users, []} ->
            Enum.filter(users, & &1.active)

          {:user_by_email, [email]} ->
            Enum.find(users, &(&1.email == email))
        end

      {result, state}
    end,
    %{}
  )

  :ok
end

test "queries see records written through Repo" do
  changeset = User.changeset(%User{}, %{name: "Alice", email: "alice@co.com", active: true})
  {:ok, _alice} = MyApp.Repo.insert(changeset)

  # The Queries handler reads from Repo's InMemory state
  assert [%User{name: "Alice"}] = MyApp.UserQueries.active_users()
  assert %User{email: "alice@co.com"} = MyApp.UserQueries.user_by_email("alice@co.com")
end
```

Because the Queries handler is set up via `Double.fake`, you can
layer expects on top for error simulation:

```elixir
MyApp.UserQueries
|> DoubleDown.Double.fake(queries_handler_fn, %{})
|> DoubleDown.Double.expect(:user_by_email, fn [_] -> nil end)
```

The `all_states` map contains the Repo's InMemory store keyed by
`DoubleDown.Repo`. The store structure is
`%{SchemaModule => %{pk_value => struct}}`, so the Queries handler
can scan, filter, and match against it.

**Key points:**

- The Repo state in the snapshot reflects all writes up to the point
  the Queries handler is called — insert then query gives consistent
  results
- The Queries handler cannot modify the Repo state — it's read-only
- The handler's own state (`state` / 3rd arg) is independent and can
  be used for Queries-specific bookkeeping if needed
- Non-PK queries require scanning the store — this is a linear scan
  over in-memory maps, which is fast for test-sized data sets

See [Cross-contract state access](testing.md#cross-contract-state-access)
in the Testing guide for the general mechanism.

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

[< Process Sharing](process-sharing.md) | [Up: README](../README.md) | [Migration >](migration.md)
