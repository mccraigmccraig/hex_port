# Testing

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Repo >](repo.md)

DoubleDown's testing system is built on
[NimbleOwnership](https://hex.pm/packages/nimble_ownership) — the same
ownership library that Mox uses internally. Each test process gets its
own handlers, state, and logs, so `async: true` works out of the box.

## Setup

Start the ownership server once in `test/test_helper.exs`:

```elixir
{:ok, _} = DoubleDown.Testing.start()
```

This starts a `NimbleOwnership` GenServer used for process-scoped test
handler isolation. In production, facades compiled with the default
`:test_dispatch?` setting use `DoubleDown.Dispatch.call_config/4`, which
doesn't reference NimbleOwnership at all — the test dispatch code path
is absent from the compiled beam files. See
[Dispatch resolution](getting-started.md#dispatch-resolution) for
details.

## Handler modes

DoubleDown provides three ways to register test handlers. All are
process-scoped and isolated between concurrent tests.

### Module handler

Register any module that implements the contract's `@behaviour`:

```elixir
DoubleDown.Testing.set_handler(MyApp.Todos, MyApp.Todos.Fake)
```

Dispatch calls `apply(MyApp.Todos.Fake, operation, args)`.

### Function handler

Register a 2-arity closure `(operation, args) -> result` with pattern
matching:

```elixir
DoubleDown.Testing.set_fn_handler(MyApp.Todos, fn
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
DoubleDown.Testing.set_stateful_handler(
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

For Ecto Repo operations specifically, DoubleDown ships ready-made
stateful test doubles — see [Repo](repo.md).

## Handler (expect/stub)

`DoubleDown.Double` provides a Mox-style expect/stub API for declaring
test handlers. Each call writes directly to NimbleOwnership — no
builder, no `install!` step. All functions return the contract module
for piping.

### Basic usage

```elixir
setup do
  MyApp.Todos
  |> DoubleDown.Double.expect(:get_todo, fn [id] -> {:ok, %Todo{id: id}} end)
  |> DoubleDown.Double.stub(:list_todos, fn [_] -> [] end)
  :ok
end

test "..." do
  # ... run code under test ...
  DoubleDown.Double.verify!()
end
```

Expectations are consumed in order. Stubs handle any number of calls
and take over after expectations are exhausted. Calling an operation
with no remaining expectations and no stub raises immediately.

### Sequenced expectations

```elixir
MyApp.Todos
|> DoubleDown.Double.expect(:get_todo, fn [_] -> {:error, :not_found} end)
|> DoubleDown.Double.expect(:get_todo, fn [id] -> {:ok, %Todo{id: id}} end)

# First call returns :not_found, second returns the todo
```

### Repeated expectations

```elixir
DoubleDown.Double.expect(MyApp.Todos, :get_todo, fn [id] -> {:ok, %Todo{id: id}} end, times: 3)
```

### Contract-wide fallback

A fallback handles any operation without a specific expect or
per-operation stub. Three forms are supported:

**Function fallback** — a 2-arity `fn operation, args -> result end`,
the same signature as `set_fn_handler`:

```elixir
MyApp.Todos
|> DoubleDown.Double.stub(fn
  :list_todos, [_] -> []
  :get_todo, [id] -> {:ok, %Todo{id: id}}
end)
|> DoubleDown.Double.expect(:create_todo, fn [p] -> {:ok, struct!(Todo, p)} end)
```

**Stateful fallback** — a 3-arity `fn op, args, state -> {result, state}` with
initial state. Same signature as `set_stateful_handler`, so stateful
fakes like `Repo.InMemory` integrate directly. Override specific
operations with expects while the fake handles everything else:

```elixir
# First insert fails with constraint error, rest go through InMemory
DoubleDown.Repo
|> DoubleDown.Double.fake(&DoubleDown.Repo.InMemory.dispatch/3, DoubleDown.Repo.InMemory.new())
|> DoubleDown.Double.expect(:insert, fn [changeset] ->
  {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
end)
```

When an expect short-circuits (returns an error), the fallback
state is unchanged — correct for error simulation.

Note: expects cannot delegate to the stateful fallback inline
(no "passthrough" callback). Threading mutable state through a
user-provided callback requires a complex API and seems of limited
value given that the main use case — error simulation — doesn't
need it. We decided to leave it out for now.

**Module fallback** — a module implementing the contract's behaviour.
Override specific operations while the rest delegate to the real
implementation:

```elixir
MyApp.Todos
|> DoubleDown.Double.fake(MyApp.Todos.Ecto)
|> DoubleDown.Double.expect(:create_todo, fn [_] -> {:error, :conflict} end)
```

The module is validated at stub time. Note: if the module's
`:bar` internally calls `:foo` and you've stubbed `:foo`, the module
won't see your stub — it calls its own `:foo` directly. For stubs to
be visible, the module must call through the facade.

Dispatch priority: expects > per-operation stubs > fallback > raise.

### Passthrough expects

When a fallback is configured, pass `:passthrough` instead of a
function to delegate to the fallback while still consuming the
expect for `verify!` counting:

```elixir
MyApp.Todos
|> DoubleDown.Double.fake(MyApp.Todos.Impl)
|> DoubleDown.Double.expect(:get_todo, :passthrough, times: 2)

# Both calls delegate to MyApp.Todos.Impl
# verify! checks that get_todo was called exactly twice
```

`:passthrough` works with all fallback types (function, stateful,
module) and threads state correctly for stateful fallbacks. It can
be mixed with function expects for patterns like "first call
succeeds through the fallback, second call returns an error":

```elixir
RepoContract
|> DoubleDown.Double.fake(&Repo.InMemory.handler/3, %{})
|> DoubleDown.Double.expect(:insert, :passthrough)
|> DoubleDown.Double.expect(:insert, fn [changeset] ->
  {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
end)

# First insert: passthrough to InMemory (writes to store)
# Second insert: expect fires, returns error (store unchanged)
```

### Multi-contract

```elixir
MyApp.Todos
|> DoubleDown.Double.expect(:create_todo, fn [p] -> {:ok, struct!(Todo, p)} end)

DoubleDown.Double.stub(DoubleDown.Repo, :one, fn [_] -> nil end)
```

### Verification

`verify!/0` checks that all expectations have been consumed. Stubs
are not checked — zero calls is valid.

The easiest approach is `verify_on_exit!/0` in a setup block — it
automatically verifies after each test, catching forgotten `verify!`
calls:

```elixir
setup :verify_on_exit!

# or equivalently:
setup do
  DoubleDown.Double.verify_on_exit!()
end
```

You can also call `verify!/0` explicitly at the end of a test:

```elixir
test "creates a todo" do
  # ... setup and dispatch ...
  DoubleDown.Double.verify!()
end
```

### When to use Handler vs raw handlers

Use `DoubleDown.Double` when you want Mox-style call counting and
ordered expectations. Use `set_fn_handler` for simple canned
responses. Use `set_stateful_handler` directly when you need custom
state management (e.g. in-memory stores with complex query logic).

## Dispatch logging

Record every call that crosses a contract boundary, then assert on
the sequence:

```elixir
setup do
  DoubleDown.Testing.enable_log(MyApp.Todos)
  DoubleDown.Testing.set_fn_handler(MyApp.Todos, fn
    :get_todo, [id] -> {:ok, %Todo{id: id}}
  end)
  :ok
end

test "logs dispatch calls" do
  MyApp.Todos.get_todo("42")

  assert [{MyApp.Todos, :get_todo, ["42"], {:ok, %Todo{id: "42"}}}] =
    DoubleDown.Testing.get_log(MyApp.Todos)
end
```

The log captures `{contract, operation, args, result}` tuples in
dispatch order. Enable logging before making calls; `get_log/1`
returns the full sequence.

## Log matcher (structured log assertions)

`DoubleDown.Log` provides structured expectations against the dispatch
log. Unlike `get_log/1` + manual assertions, it supports ordered
matching, counting, reject expectations, and strict mode.

This is particularly valuable with handlers like `Repo.Test` that
do real computation — matching on results in the log is a meaningful
assertion, not a tautology.

### Basic usage

```elixir
DoubleDown.Testing.enable_log(MyApp.Todos)
# ... set handler and dispatch ...

DoubleDown.Log.match(:create_todo, fn
  {_, _, [params], {:ok, %Todo{id: id}}} when is_binary(id) -> true
end)
|> DoubleDown.Log.reject(:delete_todo)
|> DoubleDown.Log.verify!(MyApp.Todos)
```

Matcher functions only need positive clauses — `FunctionClauseError`
is caught and treated as "didn't match". No `_ -> false` catch-all
needed, though returning `false` explicitly can be useful for
excluding specific values that are hard to exclude with pattern
matching alone.

### Counting occurrences

```elixir
DoubleDown.Log.match(:insert, fn
  {_, _, [%Changeset{data: %Discrepancy{}}], {:ok, _}} -> true
end, times: 3)
|> DoubleDown.Log.verify!(DoubleDown.Repo)
```

### Strict mode

By default, extra log entries between matchers are ignored (loose
mode). Strict mode requires every log entry to be matched:

```elixir
DoubleDown.Log.match(:insert, fn _ -> true end)
|> DoubleDown.Log.match(:update, fn _ -> true end)
|> DoubleDown.Log.verify!(MyContract, strict: true)
```

### Using with DoubleDown.Double

Handler and Log serve complementary roles — Handler for fail-fast
validation and producing return values, Log for after-the-fact
result inspection:

```elixir
# Set up handlers
DoubleDown.Double.expect(MyContract, :create, fn [p] -> {:ok, struct!(Thing, p)} end)

DoubleDown.Testing.enable_log(MyContract)

# Run code under test
MyModule.do_work(params)

# Verify handler expectations consumed
DoubleDown.Double.verify!()

# Verify log entries match expected patterns
DoubleDown.Log.match(:create, fn
  {_, _, _, {:ok, %Thing{}}} -> true
end)
|> DoubleDown.Log.verify!(MyContract)
```

## Process sharing and async safety

All test handlers are process-scoped. `async: true` tests run in full
isolation — each test process has its own handlers, state, and logs.

**Task.async children** automatically inherit their parent's handlers
via the `$callers` chain. No setup needed.

**Other processes** (plain `spawn`, Agent, GenServer) need explicit
sharing:

```elixir
DoubleDown.Testing.allow(MyApp.Todos, self(), agent_pid)
```

`allow/3` also accepts a lazy pid function for processes that don't
exist yet at setup time:

```elixir
DoubleDown.Testing.allow(MyApp.Todos, self(), fn -> GenServer.whereis(MyWorker) end)
```

### Global mode

For integration-style tests involving supervision trees, named
GenServers, Broadway pipelines, or Oban workers — where individual
process pids are not easily accessible — you can switch to global
mode:

```elixir
setup do
  DoubleDown.Testing.set_mode_to_global()
  DoubleDown.Testing.set_handler(MyApp.Todos, MyApp.Todos.InMemory)
  on_exit(fn -> DoubleDown.Testing.set_mode_to_private() end)
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

### Choosing the right approach

| Situation | Approach | `async: true`? |
|-----------|----------|----------------|
| Direct function calls | No extra setup needed | Yes |
| `Task.async` / `Task.Supervisor` | Automatic via `$callers` | Yes |
| Known pid (Agent, named GenServer) | `allow/3` with the pid | Yes |
| Pid not known at setup time | `allow/3` with lazy fn | Yes |
| Supervision tree / Broadway / Oban | `set_mode_to_global/0` | **No** |

### Example: testing a GenServer that dispatches through a contract

```elixir
defmodule MyApp.WorkerTest do
  use ExUnit.Case, async: true

  setup do
    DoubleDown.Testing.set_fn_handler(MyApp.Todos, fn
      :get_todo, [id] -> {:ok, %Todo{id: id}}
    end)

    {:ok, pid} = MyApp.Worker.start_link([])
    DoubleDown.Testing.allow(MyApp.Todos, self(), pid)

    %{worker: pid}
  end

  test "worker fetches todo via contract", %{worker: pid} do
    assert {:ok, %Todo{id: "42"}} = MyApp.Worker.fetch(pid, "42")
  end
end
```

### Example: testing through a supervision tree

When you can't easily get pids for every process in the tree, use
global mode:

```elixir
defmodule MyApp.PipelineIntegrationTest do
  use ExUnit.Case, async: false

  setup do
    DoubleDown.Testing.set_mode_to_global()

    DoubleDown.Testing.set_stateful_handler(
      DoubleDown.Repo,
      &DoubleDown.Repo.InMemory.dispatch/3,
      DoubleDown.Repo.InMemory.new()
    )

    on_exit(fn -> DoubleDown.Testing.set_mode_to_private() end)

    start_supervised!(MyApp.Pipeline)
    :ok
  end

  test "pipeline processes events end-to-end" do
    MyApp.Pipeline.enqueue(%{type: :invoice, amount: 100})
    # ... assert on results ...
  end
end
```

## Cleanup

Call `reset/0` to clear all handlers, state, and logs for the current
process:

```elixir
setup do
  DoubleDown.Testing.reset()
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
config :my_app, DoubleDown.Repo, impl: nil
```

Now any test that forgets to set a handler gets an immediate error:

    ** (RuntimeError) No test handler set for MyApp.Todos.

    In your test setup, call one of:

        DoubleDown.Testing.set_handler(MyApp.Todos, MyImpl)
        DoubleDown.Testing.set_fn_handler(MyApp.Todos, fn operation, args -> ... end)
        DoubleDown.Testing.set_stateful_handler(MyApp.Todos, handler_fn, initial_state)

Every test must explicitly declare its dependencies via
`set_handler`, `set_fn_handler`, or `set_stateful_handler`. For
integration tests that need the real implementation, use
`set_handler` with the production module:

```elixir
setup do
  DoubleDown.Testing.set_handler(MyApp.Todos, MyApp.Todos.Ecto)
  :ok
end
```

This makes the choice to use the real implementation visible and
intentional, rather than an accident of config inheritance.

## Mox compatibility

Because `defcallback` generates standard `@callback` declarations, the
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

This works because DoubleDown's dispatch resolution checks test handlers
first, then falls back to application config. When using Mox, the
config points to the mock module, and Mox's own process-scoped
expectations provide the isolation.

You can use either approach — DoubleDown's built-in handlers or Mox —
depending on your preference. DoubleDown's handlers don't require
defining mock modules or changing config, and the stateful handler
mode has no Mox equivalent.

---

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Repo >](repo.md)
