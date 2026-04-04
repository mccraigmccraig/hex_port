# Testing

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Repo >](repo.md)

HexPort's testing system is built on
[NimbleOwnership](https://hex.pm/packages/nimble_ownership) — the same
ownership library that Mox uses internally. Each test process gets its
own handlers, state, and logs, so `async: true` works out of the box.

## Setup

Start the ownership server once in `test/test_helper.exs`:

```elixir
{:ok, _} = HexPort.Testing.start()
```

This starts a `NimbleOwnership` GenServer. In production, this server
doesn't exist, so the dispatch lookup is zero-cost (a single
`GenServer.whereis` returning `nil`).

## Handler modes

HexPort provides three ways to register test handlers. All are
process-scoped and isolated between concurrent tests.

### Module handler

Register any module that implements the contract's `@behaviour`:

```elixir
HexPort.Testing.set_handler(MyApp.Todos, MyApp.Todos.Fake)
```

Dispatch calls `apply(MyApp.Todos.Fake, operation, args)`.

### Function handler

Register a 2-arity closure `(operation, args) -> result` with pattern
matching:

```elixir
HexPort.Testing.set_fn_handler(MyApp.Todos, fn
  :create_todo, [params] -> {:ok, struct!(Todo, params)}
  :get_todo, [id] -> {:ok, %Todo{id: id, title: "Test"}}
  :list_todos, [_tenant] -> [%Todo{id: "1", title: "Test"}]
end)
```

This is the most common mode for simple tests where you just need
canned return values.

### Stateful handler

Register a 3-arity closure `(operation, args, state) -> {result, new_state}`
with an initial state value:

```elixir
HexPort.Testing.set_stateful_handler(
  MyApp.Todos,
  fn
    :create_todo, [params], todos ->
      todo = struct!(Todo, Map.put(params, :id, map_size(todos) + 1))
      {{:ok, todo}, Map.put(todos, todo.id, todo)}

    :get_todo, [id], todos ->
      case Map.get(todos, id) do
        nil -> {{:error, :not_found}, todos}
        todo -> {{:ok, todo}, todos}
      end

    :list_todos, [_tenant], todos ->
      {Map.values(todos), todos}
  end,
  %{}  # initial state
)
```

State is stored in NimbleOwnership and updated atomically on each
dispatch. This gives you a lightweight in-memory store for tests that
need read-after-write consistency.

For Ecto Repo operations specifically, HexPort ships ready-made
stateful test doubles — see [Repo](repo.md).

## Dispatch logging

Record every call that crosses a port boundary, then assert on the
sequence:

```elixir
setup do
  HexPort.Testing.enable_log(MyApp.Todos)
  HexPort.Testing.set_fn_handler(MyApp.Todos, fn
    :get_todo, [id] -> {:ok, %Todo{id: id}}
  end)
  :ok
end

test "logs dispatch calls" do
  MyApp.Todos.get_todo("42")

  assert [{:get_todo, ["42"], {:ok, %Todo{id: "42"}}}] =
    HexPort.Testing.get_log(MyApp.Todos)
end
```

The log captures `{operation, args, result}` tuples in dispatch order.
Enable logging before making calls; `get_log/1` returns the full
sequence.

## Process sharing and async safety

All test handlers are process-scoped. `async: true` tests run in full
isolation — each test process has its own handlers, state, and logs.

**Task.async children** automatically inherit their parent's handlers
via the `$callers` chain. No setup needed.

**Other processes** (plain `spawn`, Agent, GenServer) need explicit
sharing:

```elixir
HexPort.Testing.allow(MyApp.Todos, self(), agent_pid)
```

`allow/3` also accepts a lazy pid function for processes that don't
exist yet at setup time:

```elixir
HexPort.Testing.allow(MyApp.Todos, self(), fn -> GenServer.whereis(MyWorker) end)
```

### Global mode

For integration-style tests involving supervision trees, named
GenServers, Broadway pipelines, or Oban workers — where individual
process pids are not easily accessible — you can switch to global
mode:

```elixir
setup do
  HexPort.Testing.set_mode_to_global()
  HexPort.Testing.set_handler(MyApp.Todos, MyApp.Todos.InMemory)
  on_exit(fn -> HexPort.Testing.set_mode_to_private() end)
  :ok
end
```

In global mode, all handlers registered by the test process are
visible to every process in the VM without explicit `allow/3` calls.

**Warning:** Global mode is incompatible with `async: true`. When
active, all tests share the same handlers, so concurrent tests will
interfere with each other. Only use global mode in tests with
`async: false`. Call `set_mode_to_private/0` in `on_exit` to restore
per-process isolation for subsequent tests.

## Cleanup

Call `reset/0` to clear all handlers, state, and logs for the current
process:

```elixir
setup do
  HexPort.Testing.reset()
  # ... set up fresh handlers ...
end
```

In practice, most tests just set handlers in `setup` without calling
`reset` — NimbleOwnership's per-process isolation means there's no
cross-test leakage.

## Fail-fast configuration

By default, if no test handler is set and your production config is
inherited into the test environment, dispatch silently hits the real
implementation. This can mask missing test setup — a test passes but
it's talking to a real database or external service.

To prevent this, override your contract configs in `config/test.exs`
with a nil implementation:

```elixir
# config/test.exs
config :my_app, MyApp.Todos, impl: nil
config :my_app, HexPort.Repo.Contract, impl: nil
```

Now any test that forgets to set a handler gets an immediate error:

    ** (RuntimeError) No test handler set for MyApp.Todos.

    In your test setup, call one of:

        HexPort.Testing.set_handler(MyApp.Todos, MyImpl)
        HexPort.Testing.set_fn_handler(MyApp.Todos, fn operation, args -> ... end)
        HexPort.Testing.set_stateful_handler(MyApp.Todos, handler_fn, initial_state)

Every test must explicitly declare its dependencies via
`set_handler`, `set_fn_handler`, or `set_stateful_handler`. For
integration tests that need the real implementation, use
`set_handler` with the production module:

```elixir
setup do
  HexPort.Testing.set_handler(MyApp.Todos, MyApp.Todos.Ecto)
  :ok
end
```

This makes the choice to use the real implementation visible and
intentional, rather than an accident of config inheritance.

## Mox compatibility

Because `defport` generates standard `@callback` declarations, the
contract module works as a Mox behaviour out of the box:

```elixir
# test/support/mocks.ex
Mox.defmock(MyApp.Todos.Mock, for: MyApp.Todos)

# config/test.exs
config :my_app, MyApp.Todos, impl: MyApp.Todos.Mock
```

```elixir
import Mox

setup :verify_on_exit!

test "get_todo returns the expected todo" do
  MyApp.Todos.Mock
  |> expect(:get_todo, fn "42" -> {:ok, %Todo{id: "42"}} end)

  assert {:ok, %Todo{id: "42"}} = MyApp.Todos.get_todo("42")
end
```

This works because HexPort's dispatch resolution checks test handlers
first, then falls back to application config. When using Mox, the
config points to the mock module, and Mox's own process-scoped
expectations provide the isolation.

You can use either approach — HexPort's built-in handlers or Mox —
depending on your preference. HexPort's handlers don't require
defining mock modules or changing config, and the stateful handler
mode has no Mox equivalent.

---

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Repo >](repo.md)
