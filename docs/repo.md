# Repo

[< Process Sharing](process-sharing.md) | [Up: README](../README.md) | [Repo Test Doubles >](repo-doubles.md)

DoubleDown ships a ready-made Ecto Repo contract behaviour
with three test double implementations (`Repo.Stub`, `Repo.InMemory`,
and `Repo.OpenInMemory`).
In production, the dispatch facade passes through to your existing Ecto
Repo with zero overhead (via static dispatch). The test doubles are
sophisticated enough to support `Ecto.Multi` transactions with rollback,
read-after-write consistency, and ExMachina factory integration — making
it realistic to test Ecto-heavy domain logic, including multi-step
transaction code, without a database and at speeds suitable for
property-based testing.

## The contract

`DoubleDown.Repo` defines these operations:

| Category         | Operations                                                                                         |
|------------------|----------------------------------------------------------------------------------------------------|
| **Writes**       | `insert`, `update`, `delete`, `insert!`, `update!`, `delete!`, `insert_or_update`, `insert_or_update!` |
| **Bulk**         | `insert_all`, `update_all`, `delete_all`                                                           |
| **Raw SQL**      | `query/1,2,3`, `query!/1,2,3`                                                                     |
| **PK reads**     | `get`, `get!`                                                                                      |
| **Non-PK reads** | `get_by`, `get_by!`, `one`, `one!`, `all`, `all_by`, `exists?`, `aggregate`                        |
| **Associations** | `preload`, `load`, `reload`, `reload!`                                                             |
| **Streaming**    | `stream`                                                                                           |
| **Transactions** | `transact`, `rollback`, `in_transaction?`                                                          |

All operations accept an optional trailing `opts` keyword list,
matching `Ecto.Repo`'s API.

Write operations return `{:ok, struct} | {:error, changeset}`.
Bang variants (`insert!`, `update!`, `delete!`, `insert_or_update!`)
return the struct directly or raise `Ecto.InvalidChangesetError`.
`insert`/`insert!` accept both changesets and bare structs (matching
Ecto.Repo). `insert_or_update` delegates to insert or update based
on changeset meta state. Raise-on-not-found variants (`get!`,
`get_by!`, `one!`) are separate contract operations mirroring
Ecto's semantics.

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

## Alternative: DynamicFacade (no facade module needed)

If your Ecto Repo module has custom functions beyond the standard
`Ecto.Repo` API, or you don't want to introduce a facade module,
use `DoubleDown.DynamicFacade` instead. It replaces the module's
bytecode with a dispatch shim at test time — no facade, no config:

```elixir
# test/test_helper.exs
DoubleDown.DynamicFacade.setup(MyApp.EctoRepo)
{:ok, _} = DoubleDown.Testing.start()
ExUnit.start()
```

Then in tests, use the Double API directly on your Ecto Repo module:

```elixir
setup do
  DoubleDown.Double.fallback(MyApp.EctoRepo, DoubleDown.Repo.InMemory)
  :ok
end

test "insert then get" do
  {:ok, user} = MyApp.EctoRepo.insert(User.changeset(%{name: "Alice"}))
  assert %User{name: "Alice"} = MyApp.EctoRepo.get(User, user.id)
end
```

This approach is particularly useful when:

- Your Repo module has **custom functions** (e.g. `soft_delete/1`,
  `with_tenant/2`) that aren't in the `DoubleDown.Repo` contract —
  DynamicFacade intercepts *all* public functions, not just contract
  operations
- You're **adopting DoubleDown incrementally** and don't want to
  introduce a wrapper module yet
- You want `expect`/`stub`/`fake` on **any function** your Repo
  exports, not just the standard Ecto operations

Tests that don't install a handler get the original Repo's behaviour
automatically — zero impact on unrelated tests. `async: true` works
via NimbleOwnership's per-process isolation, same as the ContractFacade
approach.

See [Dynamic Facades](dynamic.md) for full documentation.

## Production — zero-cost passthrough

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

## Test doubles

| Double | Type | State | Best for |
|--------|------|-------|----------|
| **`Repo.Stub`** | Stateless stub | None | Fire-and-forget writes, canned read responses |
| **`Repo.InMemory`** | Closed-world fake | `%{Schema => %{pk => struct}}` | Full in-memory store; ExMachina factories; all bare-schema reads |
| **`Repo.OpenInMemory`** | Open-world fake | `%{Schema => %{pk => struct}}` | PK-based read-after-write; fallback for other reads |

See **[Repo Test Doubles](repo-doubles.md)** for detailed documentation
of each implementation, including ExMachina integration.

See **[Repo Testing Patterns](repo-testing.md)** for failure simulation,
transactions, rollback, cross-contract state access, and dispatch
logging patterns.

## Testing without a database

The in-memory Repo removes the database from your test feedback loop.
Because there's no I/O, tests run at pure-function speed — fast enough
for property-based testing with StreamData or similar generators.

You get:

- **No sandbox, no migrations, no DB setup** — tests start instantly
- **Read-after-write consistency** — insert a record then `get` it back
- **Full Ecto.Multi support** — multi-step transactions work correctly
- **Transaction rollback** — `rollback/1` restores pre-transaction state
- **ExMachina integration** — factory-inserted records readable via
  `all`, `get_by`, `aggregate` without a database
- **Property-based testing speed** — thousands of test cases per second

This is particularly valuable for domain logic that interleaves Ecto
operations. The contract boundary lets you swap the real Repo for
`Repo.InMemory` and verify business rules without database overhead —
then use the Ecto adapter in integration tests for the full stack.

---

[< Process Sharing](process-sharing.md) | [Up: README](../README.md) | [Repo Test Doubles >](repo-doubles.md)
