# Repo Testing Patterns

[< Repo Test Doubles](repo-doubles.md) | [Up: README](../README.md) | [Migration >](migration.md)

Advanced testing patterns for `DoubleDown.Repo` — failure simulation,
transactions, cross-contract state access, and dispatch logging.

## Error simulation with Repo.Stub

Use a 3-arity function fallback (`Repo.Stub.new/1` returns one) as
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

## Error simulation with Repo.InMemory

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

## Counting calls with passthrough expects

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

## Stateful expects and stubs

Expects and per-operation stubs can be 2-arity or 3-arity to read
and update the InMemory store directly. The state passed to the
responder is the InMemory store (`%{Schema => %{pk => record}}`):

```elixir
# 2-arity expect: reject duplicate emails, otherwise passthrough
DoubleDown.Repo
|> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
|> DoubleDown.Double.fake(:insert, fn [changeset], state ->
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
and [Per-operation fakes](testing.md#per-operation-fakes)
in the Testing guide for the full API.

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

### With Ecto.Multi

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

In `Repo.InMemory`, bulk operations (`insert_all`, `update_all` with
`set:`, `delete_all`) are handled directly for bare schema sources.
In `Repo.OpenInMemory` and `Repo.Stub`, they delegate to the fallback
function or raise.

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

In the stateful test adapters (`Repo.InMemory` and `Repo.OpenInMemory`),
`rollback` restores the store to its state at the start of the
transaction — inserts, updates, and deletes within the rolled-back
transaction are undone. This is implemented by snapshotting the store
before the transaction and restoring it on rollback. Only the Repo
contract's state is restored; other contracts' state is unaffected.

`Repo.Stub` is stateless, so rollback has no state to restore — it
simply returns `{:error, value}`.

## Concurrency limitations

The **Ecto adapter** provides real database transactions with full
ACID isolation — this is the production path.

The **Stub**, **InMemory**, and **OpenInMemory** adapters support
rollback semantics but do **not** provide full ACID transaction
isolation:

- `Repo.Stub` calls the function directly without any locking or
  state (rollback returns `{:error, value}` but has no state to
  restore).
- `Repo.InMemory` and `Repo.OpenInMemory` use `%DoubleDown.Contract.Dispatch.Defer{}` to run the transaction
  function outside the NimbleOwnership lock — each sub-operation
  acquires the lock individually.

**What works:**

- `rollback/1` restores the Repo state to its pre-transaction
  snapshot. Inserts, updates, and deletes within the rolled-back
  transaction are undone.

**What doesn't:**

- Concurrent writes within a transaction are not isolated from each
  other. Sub-operations are individually atomic but not grouped.
- Other contracts' state modified during the transaction is not
  rolled back — only the Repo contract's state is restored.

This is acceptable for test-only adapters where transactions are
typically exercised in serial, single-process tests. If you need true
ACID isolation, use the Ecto adapter with a real database and
Ecto's sandbox.

## Combining with DoubleDown.Log

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

---

[< Repo Test Doubles](repo-doubles.md) | [Up: README](../README.md) | [Migration >](migration.md)
