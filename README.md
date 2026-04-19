# DoubleDown

[![Test](https://github.com/mccraigmccraig/double_down/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/double_down/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/double_down.svg)](https://hex.pm/packages/double_down)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/double_down/)

Contract boundaries and test doubles for Elixir. Define a contract
(the interface), generate a dispatch facade (what callers use), and
swap implementations at test time — with stateful fakes powerful
enough to test Ecto.Repo operations without a database.

## Why DoubleDown?

DoubleDown extends Jose Valim's
[Mocks and explicit contracts](https://dashbit.co/blog/mocks-and-explicit-contracts)
pattern:

- **Zero boilerplate** — `defcallback` generates the `@behaviour`,
  `@callback`, dispatch facade, and `@spec` from a single declaration.
  Or generate a facade from an existing `@behaviour` module, or
  use Mimic-style bytecode interception for any module. See
  [Choosing a facade type](docs/getting-started.md#choosing-a-facade-type).
- **Zero-cost production dispatch** — facades compile to inlined
  direct calls. `MyContract.do_thing(args)` produces identical
  bytecode to `DirectImpl.do_thing(args)` — the facade disappears
  entirely after BEAM inlining. Contract boundaries have no
  runtime cost.
- **When mocks are not enough: stateful fakes** — in-memory
  state with atomic updates, read-after-write consistency,
  `Ecto.Multi` transactions,  and rollback. Fast enough for
  property-based testing.
- **ExMachina factory integration** — `Repo.InMemory` works as a
  drop-in replacement for the Ecto sandbox. Factory-inserted records
  are readable via `all`, `get_by`, `aggregate` — no database, no
  sandbox, `async: true`.
- **Fakes with expectations** — layer expects over a stateful fake
  to simulate failures. First insert writes to the in-memory store,
  second returns a constraint error, subsequent reads find the first
  record.
- **Dispatch logging** — logs the full
  `{contract, operation, args, result}` tuple for every call.
  `DoubleDown.Log` provides structured pattern matching over those
  logs.

## What DoubleDown provides

### Contracts and dispatch

| Feature                    | Description                                                                   |
|----------------------------|-------------------------------------------------------------------------------|
| `defcallback` contracts    | Typed signatures with parameter names, `@doc` sync, pre-dispatch transforms   |
| Vanilla behaviour facades  | `BehaviourFacade` — dispatch facade from any existing `@behaviour` module     |
| Dynamic facades            | `DynamicFacade` — Mimic-style bytecode shim, module becomes ad-hoc contract   |
| Zero-cost static dispatch  | Inlined direct calls in production — no overhead vs calling the impl directly |
| Generated `@spec` + `@doc` | LSP-friendly on `defcallback` and `BehaviourFacade` facades                   |
| Standard `@behaviour`      | All contracts are Mox-compatible — `@behaviour` + `@callback`                 |

### Test doubles

| Feature                   | Description                                                                |
|---------------------------|----------------------------------------------------------------------------|
| Mox-style expect/stub     | `DoubleDown.Double` — ordered expectations, call counting, `verify!`       |
| Stateful fakes            | In-memory state with atomic updates via NimbleOwnership                    |
| Expect + fake composition | Layer expects over a stateful fake for failure simulation                  |
| `:passthrough` expects    | Count calls without changing behaviour                                     |
| Transaction rollback      | `rollback/1` restores pre-transaction state in InMemory fakes              |
| Dispatch logging          | Record `{contract, op, args, result}` for every call                       |
| Structured log matching   | `DoubleDown.Log` — pattern-match on logged results                         |
| Async-safe                | Process-scoped isolation via NimbleOwnership, `async: true` out of the box |

### Built-in Ecto Repo

Full `Ecto.Repo` contract (`DoubleDown.Repo`) with three test doubles:

| Double              | Type              | Best for                                                         |
|---------------------|-------------------|------------------------------------------------------------------|
| `Repo.Stub`         | Stateless stub    | Fire-and-forget writes, canned read responses                    |
| `Repo.InMemory`     | Closed-world fake | Full in-memory store; all bare-schema reads; ExMachina factories |
| `Repo.OpenInMemory` | Open-world fake   | PK-based read-after-write; fallback for other reads              |

All three support `Ecto.Multi` transactions with rollback, PK
autogeneration, changeset validation, timestamps, and both changeset
and bare struct inserts. See [Repo](docs/repo.md).

## Quick example

This example uses `defcallback` contracts — the recommended approach
for new code. For existing `@behaviour` modules, see
`DoubleDown.BehaviourFacade`. For Mimic-style interception of any
module, see `DoubleDown.DynamicFacade`.

### Define contracts

Use the built-in `DoubleDown.Repo` contract for database operations,
and define domain-specific contracts for business logic:

```elixir
# Repo facade — wraps your Ecto Repo
defmodule MyApp.Repo do
  use DoubleDown.ContractFacade, contract: DoubleDown.Repo, otp_app: :my_app
end

# Domain model contract — queries specific to your domain
defmodule MyApp.Todos.Model do
  use DoubleDown.ContractFacade, otp_app: :my_app

  defcallback active_todos(tenant_id :: String.t()) :: [Todo.t()]
  defcallback todo_exists?(tenant_id :: String.t(), title :: String.t()) :: boolean()
end
```

### Write orchestration code

The context module orchestrates domain logic using both contracts —
Repo for writes, Model for domain queries:

```elixir
defmodule MyApp.Todos do
  def create(tenant_id, params) do
    if MyApp.Todos.Model.todo_exists?(tenant_id, params.title) do
      {:error, :duplicate}
    else
      MyApp.Repo.insert(Todo.changeset(%Todo{tenant_id: tenant_id}, params))
    end
  end
end
```

### Wire up production implementations

```elixir
# config/config.exs
config :my_app, DoubleDown.Repo, impl: MyApp.EctoRepo
config :my_app, MyApp.Todos.Model, impl: MyApp.Todos.Model.Ecto
```

### Define a factory

Point [ExMachina](https://hex.pm/packages/ex_machina) at your Repo
facade (not your Ecto Repo):

```elixir
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  def todo_factory do
    %Todo{
      tenant_id: "t1",
      title: sequence(:title, &"Todo #{&1}")
    }
  end
end
```

### Test without a database

Start the ownership server in `test/test_helper.exs`:

```elixir
DoubleDown.Testing.start()
```

Test the orchestration with fakes and factories — no database, full
async isolation:

```elixir
defmodule MyApp.TodosTest do
  use ExUnit.Case, async: true
  import MyApp.Factory

  setup do
    # InMemory Repo — factory inserts land here
    DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)

    # Domain model queries read from the Repo's InMemory store
    # via cross-contract state access (4-arity fake)
    DoubleDown.Double.fake(MyApp.Todos.Model,
      fn operation, args, state, all_states ->
        repo = Map.get(all_states, DoubleDown.Repo, %{})
        todos = repo |> Map.get(Todo, %{}) |> Map.values()

        result =
          case {operation, args} do
            {:active_todos, [tenant]} ->
              Enum.filter(todos, &(&1.tenant_id == tenant))

            {:todo_exists?, [tenant, title]} ->
              Enum.any?(todos, &(&1.tenant_id == tenant and &1.title == title))
          end

        {result, state}
      end,
      %{}
    )

    :ok
  end

  test "creates a todo when no duplicate exists" do
    assert {:ok, todo} = MyApp.Todos.create("t1", %{title: "Ship it"})
    assert todo.tenant_id == "t1"

    # Read-after-write: InMemory serves from store
    assert ^todo = MyApp.Repo.get(Todo, todo.id)
  end

  test "rejects duplicate todos" do
    # Factory insert lands in InMemory store
    insert(:todo, tenant_id: "t1", title: "Ship it")

    # Model.todo_exists? reads from InMemory store, finds the duplicate
    assert {:error, :duplicate} = MyApp.Todos.create("t1", %{title: "Ship it"})
  end

  test "handles constraint violation on insert" do
    # First insert fails with constraint error
    DoubleDown.Double.expect(DoubleDown.Repo, :insert, fn [changeset] ->
      {:error, Ecto.Changeset.add_error(changeset, :title, "taken")}
    end)

    assert {:error, cs} = MyApp.Todos.create("t1", %{title: "Conflict"})
    assert {"taken", _} = cs.errors[:title]

    # Second call succeeds — expect consumed, InMemory handles it
    assert {:ok, _} = MyApp.Todos.create("t1", %{title: "Conflict"})
  end
end
```

## Documentation

- **[Getting Started](docs/getting-started.md)** — contracts, facades,
  dispatch resolution, terminology
- **[Testing](docs/testing.md)** — Double expect/stub/fake, stateful
  responders, cross-contract state access
- **[Dynamic Facades](docs/dynamic.md)** — Mimic-style bytecode
  interception, fake any module without an explicit contract
- **[Logging](docs/logging.md)** — dispatch logging, Log matchers,
  structured log assertions
- **[Process Sharing](docs/process-sharing.md)** — async safety, allow,
  global mode, supervision tree testing
- **[Repo](docs/repo.md)** — built-in Ecto Repo contract and production
  config
- **[Repo Test Doubles](docs/repo-doubles.md)** — `Repo.Stub`,
  `Repo.InMemory`, `Repo.OpenInMemory`, ExMachina integration
- **[Repo Testing Patterns](docs/repo-testing.md)** — failure
  simulation, transactions, rollback, cross-contract state
- **[Migration](docs/migration.md)** — incremental adoption, coexisting
  with direct Ecto.Repo calls

## Installation

Add `double_down` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:double_down, "~> 0.25"}
  ]
end
```

Ecto is an optional dependency — add it to your own deps if you want
the built-in Repo contract.

## Relationship to Skuld

DoubleDown extracts the contract and test double system from
[Skuld](https://github.com/mccraigmccraig/skuld) (algebraic effects
for Elixir) into a standalone library. You get typed contracts,
async-safe test doubles, and dispatch logging without needing Skuld's
effect system. Skuld depends on DoubleDown and layers effectful dispatch
on top.

## License

MIT License - see [LICENSE](LICENSE) for details.
