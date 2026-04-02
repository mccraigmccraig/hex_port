# HexPort

[![Test](https://github.com/mccraigmccraig/hex_port/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/hex_port/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/hex_port.svg)](https://hex.pm/packages/hex_port)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/hex_port/)

Hexagonal architecture ports for Elixir — typed contracts, async-safe
stateful test doubles, and a built-in in-memory Repo that makes database-free
testing practical.

## The problem

Clean Architecture tells you to put domain logic behind port boundaries,
but in practice a couple of things get in the way: maintaining contract
behaviours and dispatch facades involves boilerplate that's tedious to keep
in sync, and unit-testing with complex dependencies like Ecto is hard enough
that most projects never do it - they just hit the database for every test
and accept the speed penalty and the inability to adopt property-based testing.

## What HexPort does

| Feature                       | Description                                                      |
|-------------------------------|------------------------------------------------------------------|
| Typed contracts               | `defport` declarations with full typespecs                       |
| Contract behaviour generation | Standard `@behaviour` + `@callback` — Mox-compatible             |
| Dispatch facades              | `HexPort.Facade` generates config-dispatched caller functions    |
| LSP-friendly docs             | `@doc` tags on facade functions with types and parameter names   |
| Async-safe test doubles       | Process-scoped handlers via NimbleOwnership                      |
| Stateful test handlers        | In-memory state with atomic updates and fallback dispatch        |
| Dispatch logging              | Record every call that crosses a port boundary                   |
| Built-in Repo contract        | 15-operation Ecto Repo contract with stateless + in-memory impls |

## Quick example

Define a port contract and facade in one module:

```elixir
defmodule MyApp.Todos do
  use HexPort.Facade, otp_app: :my_app

  defport create_todo(params :: map()) ::
    {:ok, Todo.t()} | {:error, Ecto.Changeset.t()}

  defport get_todo(id :: String.t()) ::
    {:ok, Todo.t()} | {:error, :not_found}

  defport list_todos(tenant_id :: String.t()) :: [Todo.t()]
end
```

Implement the behaviour:

```elixir
defmodule MyApp.Todos.Ecto do
  @behaviour MyApp.Todos

  @impl true
  def create_todo(params), do: MyApp.Repo.insert(Todo.changeset(params))

  @impl true
  def get_todo(id) do
    case MyApp.Repo.get(Todo, id) do
      nil -> {:error, :not_found}
      todo -> {:ok, todo}
    end
  end

  # ...
end
```

Wire it up:

```elixir
# config/config.exs
config :my_app, MyApp.Todos, impl: MyApp.Todos.Ecto
```

Test with an in-memory test double — no database, full async isolation:

```elixir
# test/test_helper.exs
HexPort.Testing.start()

# test/my_app/todos_test.exs
defmodule MyApp.TodosTest do
  use ExUnit.Case, async: true

  setup do
    HexPort.Testing.set_stateful_handler(
      MyApp.Todos,
      fn
        :create_todo, [params], todos ->
          todo = struct!(Todo, Map.put(params, :id, System.unique_integer()))
          {{:ok, todo}, Map.put(todos, todo.id, todo)}

        :get_todo, [id], todos ->
          case Map.get(todos, id) do
            nil -> {{:error, :not_found}, todos}
            todo -> {{:ok, todo}, todos}
          end

        :list_todos, [_tenant], todos ->
          {Map.values(todos), todos}
      end,
      %{}  # initial state — empty store
    )
    :ok
  end

  test "create then get" do
    {:ok, todo} = MyApp.Todos.create_todo(%{title: "Ship it"})
    assert {:ok, ^todo} = MyApp.Todos.get_todo(todo.id)
  end

  test "get non-existent returns error" do
    assert {:error, :not_found} = MyApp.Todos.get_todo(-1)
  end
end
```

No Mox modules, no database, no sandbox — just a function that
maintains state. Each test process gets its own isolated state via
NimbleOwnership.

For Ecto-heavy code, HexPort also ships `Repo.InMemory` — a
ready-made stateful test double for the built-in Repo contract with
read-after-write consistency, `Ecto.Multi` support, and speeds suitable
for property-based testing. See [Repo](docs/repo.md).

## Documentation

- **[Getting Started](docs/getting-started.md)** — contracts, facades,
  behaviours, config, dispatch resolution
- **[Testing](docs/testing.md)** — handler modes, dispatch logging,
  async safety, Mox compatibility
- **[Repo](docs/repo.md)** — built-in Ecto Repo contract, production
  adapter, stateless and in-memory test doubles

## Installation

Add `hex_port` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hex_port, "~> x.y"}
  ]
end
```

Check [hex.pm/packages/hex_port](https://hex.pm/packages/hex_port) for the latest version.

Ecto is an optional dependency. If you want the built-in Repo contract,
add Ecto to your own deps.

## Relationship to Skuld

HexPort extracts the port system from
[Skuld](https://github.com/mccraigmccraig/skuld) (algebraic effects
for Elixir) into a standalone library. You get typed contracts,
async-safe test doubles, and dispatch logging without needing Skuld's
effect system. Skuld depends on HexPort and layers effectful dispatch
on top.

## License

MIT License - see [LICENSE](LICENSE) for details.
