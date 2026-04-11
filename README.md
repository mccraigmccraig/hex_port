# DoubleDown

[![Test](https://github.com/mccraigmccraig/double_down/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/double_down/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/double_down.svg)](https://hex.pm/packages/double_down)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/double_down/)

Builds on the Mox pattern — generates behaviours and dispatch facades
from `defport` declarations — and adds stateful test doubles powerful
enough to test Ecto.Repo operations without a database.

## Why DoubleDown?

DoubleDown builds on the familiar Mox pattern and extends it:

- **Boilerplate & consistency** — `defport` generates the behaviour,
  callbacks, dispatch facade, and typespecs from a single declaration.
  The behaviour and facade are always in sync — no hand-maintained
  boilerplate to drift.
- **Stubs are not always enough** — modelling stateful dependencies
  like a database with plain mocks is verbose and fragile, so most
  projects just hit the real DB and accept the speed penalty.
  DoubleDown's stateful handlers maintain in-memory state with atomic
  updates, giving you read-after-write consistency without a database
  — fast enough for property-based testing.
- **Fakes with expectations** — testing "what happens when the second
  insert fails with a constraint violation?" means either a real DB
  or a mock that responds to each Repo call individually — verbose and
  brittle. DoubleDown lets you layer expects over a stateful fake:
  the first insert writes to an in-memory store, the second returns
  an error, and subsequent reads find the first record.
- **Dispatch logging** — when test doubles do real computation
  (changeset validation, PK autogeneration, timestamps), the results
  are worth asserting on. DoubleDown logs the full
  `{contract, operation, args, result}` tuple for every call, and
  `DoubleDown.Log` provides structured pattern matching over those
  logs.

## What DoubleDown provides

### System boundaries (the Mox pattern, automated)

| Feature                | Description                                                     |
|------------------------|-----------------------------------------------------------------|
| `defport` declarations | Typed function signatures with parameter names and return types |
| Behaviour generation   | Standard `@behaviour` + `@callback` — Mox-compatible            |
| Dispatch facades       | Config-dispatched caller functions, generated automatically     |
| LSP-friendly           | `@doc` and `@spec` on every generated function                  |

### Test doubles (beyond Mox)

| Feature                            | Description                                                                |
|------------------------------------|----------------------------------------------------------------------------|
| Mox-style expect/stub              | `DoubleDown.Handler` — ordered expectations, call counting, `verify!`      |
| Stateful fakes                     | In-memory state with atomic updates via NimbleOwnership                    |
| Expect + fake composition          | Layer expects over a stateful fake for failure simulation                  |
| `:passthrough` expects             | Count calls without changing behaviour                                     |
| Module/function/stateful fallbacks | Dispatch priority chain: expects > stubs > fallback > raise                |
| Dispatch logging                   | Record `{contract, op, args, result}` for every call                       |
| Structured log matching            | `DoubleDown.Log` — pattern-match on logged results                         |
| Built-in Ecto Repo                 | 16-operation contract with `Repo.Test` and `Repo.InMemory` fakes           |
| Async-safe                         | Process-scoped isolation via NimbleOwnership, `async: true` out of the box |

## Quick example

Define a contract and facade in one module:

```elixir
defmodule MyApp.Todos do
  use DoubleDown.Facade, otp_app: :my_app

  defport create_todo(params :: map()) ::
    {:ok, Todo.t()} | {:error, Ecto.Changeset.t()}

  defport get_todo(id :: String.t()) ::
    {:ok, Todo.t()} | {:error, :not_found}

  defport list_todos(tenant_id :: String.t()) :: [Todo.t()]
end
```

Wire it up:

```elixir
# config/config.exs
config :my_app, MyApp.Todos, impl: MyApp.Todos.Ecto
```

Test with expects and stubs — no database, full async isolation:

```elixir
setup do
  MyApp.Todos
  |> DoubleDown.Handler.expect(:create_todo, fn [params] ->
    {:ok, struct!(Todo, Map.put(params, :id, "123"))}
  end)
  |> DoubleDown.Handler.stub(:get_todo, fn [id] -> {:ok, %Todo{id: id}} end)
  |> DoubleDown.Handler.stub(:list_todos, fn [_] -> [] end)
  :ok
end

test "create then get" do
  {:ok, todo} = MyApp.Todos.create_todo(%{title: "Ship it"})
  assert {:ok, _} = MyApp.Todos.get_todo(todo.id)
  DoubleDown.Handler.verify!()
end
```

### Testing failure scenarios

Layer expects over a stateful fake to simulate specific failures:

```elixir
setup do
  # InMemory Repo as the baseline — real state, read-after-write
  DoubleDown.Repo.Contract
  |> DoubleDown.Handler.stub(&DoubleDown.Repo.InMemory.dispatch/3,
    DoubleDown.Repo.InMemory.new())
  # First insert fails with constraint error
  |> DoubleDown.Handler.expect(:insert, fn [changeset] ->
    {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
  end)
  :ok
end

test "retries after constraint violation" do
  changeset = User.changeset(%User{}, %{email: "alice@example.com"})

  # First insert: expect fires, returns error
  assert {:error, _} = MyApp.Repo.insert(changeset)

  # Second insert: falls through to InMemory, writes to store
  assert {:ok, user} = MyApp.Repo.insert(changeset)

  # Read-after-write: InMemory serves from store
  assert ^user = MyApp.Repo.get(User, user.id)
end
```

## Documentation

- **[Getting Started](docs/getting-started.md)** — contracts, facades,
  dispatch resolution, terminology
- **[Testing](docs/testing.md)** — Handler expect/stub, dispatch
  logging, Log matchers, async safety, process sharing
- **[Repo](docs/repo.md)** — built-in Ecto Repo contract, `Repo.Test`,
  `Repo.InMemory`, failure scenario testing
- **[Migration](docs/migration.md)** — incremental adoption, coexisting
  with direct Ecto.Repo calls

## Installation

Add `double_down` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:double_down, "~> 0.24"}
  ]
end
```

Ecto is an optional dependency — add it to your own deps if you want
the built-in Repo contract.

## Relationship to Skuld

DoubleDown extracts the port system from
[Skuld](https://github.com/mccraigmccraig/skuld) (algebraic effects
for Elixir) into a standalone library. You get typed contracts,
async-safe test doubles, and dispatch logging without needing Skuld's
effect system. Skuld depends on DoubleDown and layers effectful dispatch
on top.

## License

MIT License - see [LICENSE](LICENSE) for details.
