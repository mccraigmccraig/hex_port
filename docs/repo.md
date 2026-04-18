# Repo

[< Process Sharing](process-sharing.md) | [Up: README](../README.md) | [Migration >](migration.md)

DoubleDown ships a ready-made Ecto Repo contract behaviour
with three test double implementations (`Repo.Stub`, `Repo.InMemory`,
and `Repo.OpenInMemory`).
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
  use DoubleDown.ContractFacade, contract: DoubleDown.Repo, otp_app: :my_app
end
```

This generates dispatch functions (`MyApp.Repo.insert/1`,
`MyApp.Repo.get/2`, etc.) that dispatch to the configured
implementation.

## Implementations

| Implementation | Type | State | Best for |
|----------------|------|-------|----------|
| **Your Ecto Repo** | Production | Real database | Production dispatch (zero-cost passthrough) |
| **`Repo.Stub`** | Stateless stub | None | Fire-and-forget writes, canned read responses |
| **`Repo.InMemory`** | Stateful fake (closed-world) | `%{Schema => %{pk => struct}}` | Full in-memory store; ExMachina factories; all bare-schema reads without fallback |
| **`Repo.OpenInMemory`** | Stateful fake (open-world) | `%{Schema => %{pk => struct}}` | PK-based read-after-write; fallback for other reads |

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

### `Repo.Stub` — stateless test double

A fire-and-forget adapter. Write operations apply changeset changes
and return `{:ok, struct}`, but nothing is stored. Read operations
delegate to an optional fallback function, or raise with an actionable
error message.

`Repo.Stub` implements `DoubleDown.Contract.Dispatch.StubHandler` and can be
used by module name with `Double.stub`:

```elixir
# Writes only — reads will raise with a suggestion:
DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Stub)

# With fallback for reads:
DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Stub,
  fn
    :get, [User, 1] -> %User{id: 1, name: "Alice"}
    :all, [User] -> [%User{id: 1, name: "Alice"}]
    :exists?, [User] -> true
  end
)
```

Use `Repo.Stub` when your test only needs fire-and-forget writes and
a few canned read responses. For read-after-write consistency, use
`Repo.InMemory`.

### Shared behaviour: writes, PK autogeneration, timestamps

All three test doubles share these behaviours for write operations:

- **Changeset validation** — if `changeset.valid?` is `false`, the
  operation returns `{:error, changeset}` without side effects,
  matching real Ecto Repo behaviour.
- **Primary key autogeneration** — `:id` (auto-increment), `:binary_id`
  (UUID), parameterized types (`Ecto.UUID`, `Uniq.UUID` etc.),
  `@primary_key false`, and `autogenerate: false` are all handled
  via Ecto schema metadata. Explicitly set PK values are preserved.
- **Timestamps** — `inserted_at`/`updated_at` are auto-populated on
  insert and refreshed on update via `__schema__(:autogenerate)`.
  Custom field names and types are handled automatically. Explicitly
  set timestamps are preserved.

The stateful fakes (`InMemory` and `OpenInMemory`) also support
**seed data** — pre-populate the store by passing a list of structs
as the third argument to `Double.fake`:

    DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory,
      [%User{id: 1, name: "Alice"}, %Item{id: 1, sku: "widget"}])

### `Repo.InMemory` — stateful test double (closed-world, recommended)

`Repo.InMemory` uses **closed-world semantics**: the state is
the complete truth. If a record isn't in the state, it doesn't
exist. This makes the adapter authoritative for all bare schema
operations without needing a fallback — the fallback becomes the
escape hatch for `Ecto.Query` queryables, not the default path.

**This is the recommended Repo fake for most tests.**

| Category | Operations | Behaviour |
|----------|-----------|-----------|
| **Writes** | `insert`, `update`, `delete` | Store in state |
| **PK reads** | `get`, `get!` | Return `nil` / raise on miss (no fallback) |
| **Clause reads** | `get_by`, `get_by!` | Scan and filter all records |
| **Collection reads** | `all`, `one`/`one!`, `exists?` | Scan all records of schema |
| **Aggregates** | `aggregate` | Compute from records in state |
| **Bulk writes** | `insert_all`, `delete_all`, `update_all` (`set:`) | Modify state directly |
| **Transactions** | `transact`, `rollback` | Delegate to sub-operations |
| **Ecto.Query** | Any operation with `Ecto.Query` queryable | Fallback or error |

#### Basic usage

```elixir
setup do
  DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)
  :ok
end

test "insert then read back" do
  {:ok, user} = MyApp.Repo.insert(User.changeset(%{name: "Alice"}))
  assert ^user = MyApp.Repo.get(User, user.id)
  assert [^user] = MyApp.Repo.all(User)
  assert %User{} = MyApp.Repo.get_by(User, name: "Alice")
end
```

#### ExMachina integration

`Repo.InMemory` works with [ExMachina](https://hex.pm/packages/ex_machina)
factories as a drop-in replacement for the Ecto sandbox. Factory
`insert` calls go through the Repo facade dispatch, land in the
InMemory store, and all subsequent reads work — `all`, `get_by`,
`aggregate`, etc. No database, no sandbox, `async: true`, at
speeds suitable for property-based testing.

**Step 1: Define your factory**

Point ExMachina at your Repo facade module (not your Ecto Repo):

```elixir
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  def user_factory do
    %MyApp.User{
      name: sequence(:name, &"User #{&1}"),
      email: sequence(:email, &"user#{&1}@example.com"),
      age: 25
    }
  end
end
```

**Step 2: Set up InMemory in your test**

```elixir
defmodule MyApp.SomeTest do
  use ExUnit.Case, async: true
  import MyApp.Factory

  setup do
    DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)
    :ok
  end

  test "factory-inserted records are readable" do
    insert(:user, name: "Alice", email: "alice@example.com")
    insert(:user, name: "Bob", email: "bob@example.com")

    # All bare-schema reads work — no fallback needed
    assert [_, _] = MyApp.Repo.all(User)
    assert %User{name: "Alice"} = MyApp.Repo.get_by(User, email: "alice@example.com")
    assert 2 = MyApp.Repo.aggregate(User, :count, :id)
  end

  test "read-after-write consistency" do
    user = insert(:user, name: "Alice")
    assert ^user = MyApp.Repo.get(User, user.id)
  end

  test "failure simulation over factory data" do
    insert(:user, name: "Alice")
    insert(:user, name: "Bob")

    # Intercept the next insert! to simulate a constraint error
    DoubleDown.Double.expect(DoubleDown.Repo, :insert!, fn [struct] ->
      cs = Ecto.Changeset.change(struct) |> Ecto.Changeset.add_error(:name, "taken")
      raise Ecto.InvalidChangesetError, action: :insert, changeset: cs
    end)

    assert_raise Ecto.InvalidChangesetError, fn ->
      insert(:user, name: "Carol")
    end

    # Existing records are unaffected
    assert 2 = MyApp.Repo.aggregate(User, :count, :id)
  end
end
```

This gives you the same developer experience as the Ecto sandbox —
factories write records, reads find them — but without a database
process, without sandbox checkout, and at pure-function speed.

For a complete working example, see
[`test/double_down/repo/ex_machina_test.exs`](https://github.com/mccraigmccraig/double_down/blob/main/test/double_down/repo/ex_machina_test.exs)
in the DoubleDown source.

#### Ecto.Query fallback

The fallback function is available as an escape hatch for
`Ecto.Query` queryables that cannot be evaluated in-memory:

```elixir
DoubleDown.Double.fake(
  DoubleDown.Repo,
  DoubleDown.Repo.InMemory,
  [],
  fallback_fn: fn
    :all, [%Ecto.Query{}], _state -> []
  end
)
```

### `Repo.OpenInMemory` — stateful test double (open-world)

`Repo.OpenInMemory` uses **open-world semantics**: the state may
be incomplete. When a record is not found, the adapter falls through
to a user-supplied fallback function rather than returning `nil`.
Use this when you need fine-grained control over which reads come
from state vs fallback.

For most tests, prefer `Repo.InMemory` (closed-world) which handles
all bare-schema reads without a fallback.

| Category | Operations | Behaviour |
|----------|-----------|-----------|
| **Writes** | `insert`, `update`, `delete` | Store in state |
| **PK reads** | `get`, `get!` | State first, then fallback |
| **get_by** | `get_by`, `get_by!` | PK lookup when PK in clauses, then fallback |
| **Other reads** | `one`, `all`, `exists?`, `aggregate` | Always fallback |
| **Bulk** | `insert_all`, `update_all`, `delete_all` | Always fallback |
| **Transactions** | `transact`, `rollback` | Delegate to sub-operations |

#### Basic usage — writes and PK reads

If your test only needs writes and PK-based lookups, no fallback is
needed:

```elixir
setup do
  DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.OpenInMemory)
  :ok
end

test "insert then get by PK" do
  {:ok, user} = MyApp.Repo.insert(User.changeset(%{name: "Alice"}))
  assert ^user = MyApp.Repo.get(User, user.id)
end
```

#### Fallback function for non-PK reads

For operations the state cannot answer, supply a `fallback_fn`.
The fallback receives `(operation, args, state)` where `state` is
the clean store map (internal keys stripped):

```elixir
DoubleDown.Double.fake(
  DoubleDown.Repo,
  DoubleDown.Repo.OpenInMemory,
  [%User{id: 1, name: "Alice", email: "alice@example.com"}],
  fallback_fn: fn
    :get_by, [User, [email: email]], _state -> %User{id: 1, email: email}
    :all, [User], state -> state |> Map.get(User, %{}) |> Map.values()
  end
)
```

#### Error on unhandled operations

When an operation can't be served by either state or fallback,
`Repo.OpenInMemory` raises `ArgumentError` with a message showing the
exact operation and suggesting how to add a fallback clause.

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

All three Repo test doubles share a `MultiStepper` module that walks
through Multi operations without a real database.

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

The **Stub**, **InMemory**, and **OpenInMemory** adapters do **not**
provide true transaction isolation:

- `Repo.Stub` calls the function directly without any locking.
- `Repo.InMemory` and `Repo.OpenInMemory` use `%DoubleDown.Contract.Dispatch.Defer{}` to run the transaction
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

`DoubleDown.Double` integrates with all Repo test doubles, letting you
override specific operations to simulate failures while the rest of
the Repo behaves normally.

### Error simulation with `Repo.Stub`

Use a 2-arity function fallback (`Repo.Stub.new/1` returns one) as
the Double's fallback stub, and add expects for the operations that
should fail:

```elixir
setup do
  DoubleDown.Repo
  |> DoubleDown.Double.stub(DoubleDown.Repo.Stub)
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

  # Second insert succeeds (falls through to Repo.Stub)
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
