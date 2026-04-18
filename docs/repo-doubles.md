# Repo Test Doubles

[< Repo](repo.md) | [Up: README](../README.md) | [Repo Testing Patterns >](repo-testing.md)

DoubleDown ships three test doubles for the `DoubleDown.Repo` contract.
Each is designed for a different testing scenario:

| Double | Type | State | Best for |
|--------|------|-------|----------|
| **`Repo.Stub`** | Stateless stub | None | Fire-and-forget writes, canned read responses |
| **`Repo.InMemory`** | Closed-world fake | `%{Schema => %{pk => struct}}` | Full in-memory store; ExMachina factories; all bare-schema reads |
| **`Repo.OpenInMemory`** | Open-world fake | `%{Schema => %{pk => struct}}` | PK-based read-after-write; fallback for other reads |

## Shared behaviour

All three test doubles share these behaviours for write operations:

- **Changeset validation** — if `changeset.valid?` is `false`, the
  operation returns `{:error, changeset}` without side effects,
  matching real Ecto Repo behaviour.
- **Bare struct inserts** — `insert`/`insert!` accept both
  `Ecto.Changeset` and bare structs (matching Ecto.Repo).
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

## Repo.Stub

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

## Repo.InMemory (recommended)

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
| **Transactions** | `transact`, `rollback` | Delegate to sub-operations; rollback restores state |
| **Ecto.Query** | Any operation with `Ecto.Query` queryable | Fallback or error |

### Basic usage

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

### Ecto.Query fallback

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

## ExMachina integration

`Repo.InMemory` works with [ExMachina](https://hex.pm/packages/ex_machina)
factories as a drop-in replacement for the Ecto sandbox. Factory
`insert` calls go through the Repo facade dispatch, land in the
InMemory store, and all subsequent reads work — `all`, `get_by`,
`aggregate`, etc. No database, no sandbox, `async: true`, at
speeds suitable for property-based testing.

### Step 1: Define your factory

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

### Step 2: Set up InMemory in your test

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

## Repo.OpenInMemory

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
| **Transactions** | `transact`, `rollback` | Delegate to sub-operations; rollback restores state |

### Basic usage — writes and PK reads

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

### Fallback function for non-PK reads

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

### Error on unhandled operations

When an operation can't be served by either state or fallback,
`Repo.OpenInMemory` raises `ArgumentError` with a message showing the
exact operation and suggesting how to add a fallback clause.

---

[< Repo](repo.md) | [Up: README](../README.md) | [Repo Testing Patterns >](repo-testing.md)
