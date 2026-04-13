# Testing

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Repo >](repo.md)

DoubleDown provides Mox/Mimic-style `expect`, `stub`, and `verify!`
APIs via `DoubleDown.Double`, extended with stateful fakes that model
real dependencies like Ecto.Repo. Layering expectations on top of
stateful fakes allows compact, less fragile tests for failure
scenarios — without a database. Dispatch logging and structured log
matching (`DoubleDown.Log`) let you assert on computed results, not
just call counts.

DoubleDown's testing system is built on
[NimbleOwnership](https://hex.pm/packages/nimble_ownership) — the same
ownership library that Mox uses internally. Each test process gets its
own doubles, state, and logs, so `async: true` works out of the box.

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

## Double (expect/stub/fake)

`DoubleDown.Double` is the primary API for setting up test doubles.
Each call writes directly to NimbleOwnership — no builder, no
`install!` step. All functions return the contract module for piping.

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

### Contract-wide fallback (stub or fake)

A fallback handles any operation without a specific expect or
per-operation stub. Three forms are supported:

**Stateless stub** — a 2-arity
`fn operation, args -> result end`:

```elixir
MyApp.Todos
|> DoubleDown.Double.stub(fn
  :list_todos, [_] -> []
  :get_todo, [id] -> {:ok, %Todo{id: id}}
end)
|> DoubleDown.Double.expect(:create_todo, fn [p] -> {:ok, struct!(Todo, p)} end)
```

**Stateful fake** — a module implementing
`DoubleDown.Dispatch.FakeHandler`, or a 3/4-arity function with
initial state. Fakes like `Repo.InMemory` implement FakeHandler
and integrate directly by module name:

```elixir
# FakeHandler module — simplest form
DoubleDown.Repo
|> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
|> DoubleDown.Double.expect(:insert, fn [changeset] ->
  {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
end)

# With seed data
DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory,
  [%User{id: 1, name: "Alice"}])

# With seed data and options
DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory,
  [%User{id: 1, name: "Alice"}],
  fallback_fn: fn :all, [User], state -> Map.values(state[User]) end)

# Function form (still supported)
DoubleDown.Double.fake(DoubleDown.Repo,
  &DoubleDown.Repo.InMemory.dispatch/3,
  DoubleDown.Repo.InMemory.new())
```

When a 1-arity expect short-circuits (returns an error), the fake
state is unchanged — correct for error simulation. Expects can also
be stateful — see [Stateful expect responders](#stateful-expect-responders).

**Module fake** — a module implementing the contract's behaviour.
Override specific operations while the rest delegate to the real
implementation:

```elixir
MyApp.Todos
|> DoubleDown.Double.fake(MyApp.Todos.Ecto)
|> DoubleDown.Double.expect(:create_todo, fn [_] -> {:error, :conflict} end)
```

The module is validated at `fake` time. Note: if the module's
`:bar` internally calls `:foo` and you've stubbed `:foo`, the module
won't see your stub — it calls its own `:foo` directly. For stubs to
be visible, the module must call through the facade.

Dispatch priority: expects > per-operation stubs > fallback/fake > raise.

### Passthrough expects

When a fallback/fake is configured, pass `:passthrough` instead of a
function to delegate while still consuming the expect for `verify!`
counting:

```elixir
MyApp.Todos
|> DoubleDown.Double.fake(MyApp.Todos.Impl)
|> DoubleDown.Double.expect(:get_todo, :passthrough, times: 2)

# Both calls delegate to MyApp.Todos.Impl
# verify! checks that get_todo was called exactly twice
```

`:passthrough` works with all fallback types (function, stateful,
module) and threads state correctly for stateful fakes. It can be
mixed with function expects for patterns like "first call succeeds
through the fake, second call returns an error":

```elixir
DoubleDown.Repo
|> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
|> DoubleDown.Double.expect(:insert, :passthrough)
|> DoubleDown.Double.expect(:insert, fn [changeset] ->
  {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
end)

# First insert: passthrough to InMemory (writes to store)
# Second insert: expect fires, returns error (store unchanged)
```

### Stateful expect responders

By default, expect responders are 1-arity (`fn [args] -> result end`)
and stateless — they can't see or modify the fake's state. When a
stateful fake is configured via `fake/3`, expects can also be
2-arity or 3-arity to access and update the fake's state:

```elixir
# 1-arity (default) — stateless, returns bare result
DoubleDown.Double.expect(Contract, :op, fn [args] -> result end)

# 2-arity — receives and updates the fake's state
DoubleDown.Double.expect(Contract, :op, fn [args], state ->
  {result, new_state}
end)

# 3-arity — same + read-only cross-contract state snapshot
DoubleDown.Double.expect(Contract, :op, fn [args], state, all_states ->
  {result, new_state}
end)
```

2-arity and 3-arity responders **must** return `{result, new_state}`.
Returning a bare value raises `ArgumentError` at dispatch time.

Stateful responders require `fake/3` to be called **before**
`expect` — the fake provides the state. Calling `expect` with a
2-arity or 3-arity function without a stateful fake raises
`ArgumentError` immediately.

**Example: insert fails if duplicate email, otherwise delegates to
the fake**

```elixir
DoubleDown.Repo
|> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
|> DoubleDown.Double.expect(:insert, :passthrough)
|> DoubleDown.Double.expect(:insert, fn [changeset], state ->
  # state is the InMemory store: %{Schema => %{pk => record}}
  existing_emails =
    state
    |> Map.get(User, %{})
    |> Map.values()
    |> Enum.map(& &1.email)

  email = Ecto.Changeset.get_field(changeset, :email)

  if email in existing_emails do
    {{:error, Ecto.Changeset.add_error(changeset, :email, "taken")}, state}
  else
    # No duplicate — let InMemory handle it normally
    DoubleDown.Double.passthrough()
  end
end)
```

When a responder returns `Double.passthrough()`, the call is
delegated to the fallback/fake as if it were a `:passthrough` expect.
The expect is still consumed for `verify!` counting. This avoids
duplicating the fake's logic in the else branch.

State threads through sequenced expects — each expect sees the
state left by the previous one. When a 1-arity expect fires
between stateful expects, the state is unchanged (1-arity expects
don't touch state).

### Stateful per-operation stubs

Per-operation stubs support the same arities as expects — 1-arity
(stateless), 2-arity (stateful), and 3-arity (cross-contract).
All arities can return `Double.passthrough()`.

This is the natural fit when you want to intercept every call to
an operation and decide per-call whether to handle or delegate,
without knowing the call count in advance:

```elixir
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
    DoubleDown.Double.passthrough()
  end
end)
```

Unlike expects, stubs are not consumed — they handle every call
indefinitely. Stateful stubs require `fake/3` to be called first,
same as stateful expects.

### Multi-contract

```elixir
MyApp.Todos
|> DoubleDown.Double.expect(:create_todo, fn [p] -> {:ok, struct!(Todo, p)} end)

DoubleDown.Double.stub(DoubleDown.Repo, :one, fn [_] -> nil end)
```

### Verification

`verify!/0` checks that all expectations have been consumed. Stubs
and fakes are not checked — zero calls is valid.

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

## Dispatch logging

Record every call that crosses a contract boundary, then assert on
the sequence:

```elixir
setup do
  MyApp.Todos
  |> DoubleDown.Double.stub(:get_todo, fn [id] -> {:ok, %Todo{id: id}} end)

  DoubleDown.Testing.enable_log(MyApp.Todos)
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

This is particularly valuable with fakes like `Repo.Test` that do
real computation — matching on results in the log is a meaningful
assertion, not a tautology.

### Basic usage

```elixir
DoubleDown.Testing.enable_log(MyApp.Todos)
# ... set up double and dispatch ...

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

Double and Log serve complementary roles — Double for fail-fast
validation and producing return values, Log for after-the-fact
result inspection:

```elixir
# Set up double
DoubleDown.Double.expect(MyContract, :create, fn [p] -> {:ok, struct!(Thing, p)} end)

DoubleDown.Testing.enable_log(MyContract)

# Run code under test
MyModule.do_work(params)

# Verify expectations consumed
DoubleDown.Double.verify!()

# Verify log entries match expected patterns
DoubleDown.Log.match(:create, fn
  {_, _, _, {:ok, %Thing{}}} -> true
end)
|> DoubleDown.Log.verify!(MyContract)
```

## Process sharing and async safety

All test doubles are process-scoped. `async: true` tests run in full
isolation — each test process has its own doubles, state, and logs.

**Task.async children** automatically inherit their parent's doubles
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

  DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)

  on_exit(fn -> DoubleDown.Testing.set_mode_to_private() end)
  :ok
end
```

In global mode, all doubles registered by the test process are
visible to every process in the VM without explicit `allow/3` calls.

**Warning:** Global mode is incompatible with `async: true`. When
active, all tests share the same doubles, so concurrent tests will
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
    MyApp.Todos
    |> DoubleDown.Double.stub(:get_todo, fn [id] -> {:ok, %Todo{id: id}} end)

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

    DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)

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

Call `reset/0` to clear all doubles, state, and logs for the current
process:

```elixir
setup do
  DoubleDown.Testing.reset()
  # ... set up fresh doubles ...
end
```

In practice, most tests just set doubles in `setup` without calling
`reset` — NimbleOwnership's per-process isolation means there's no
cross-test leakage.

## Fail-fast configuration

By default, if no test double is set and your production config is
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

Now any test that forgets to set up a double gets an immediate error:

    ** (RuntimeError) No test handler set for MyApp.Todos.

    In your test setup, call one of:

        DoubleDown.Double.stub(MyApp.Todos, :op, fn [args] -> result end)
        DoubleDown.Double.fake(MyApp.Todos, MyApp.Todos.Impl)

Every test must explicitly declare its dependencies. For integration
tests that need the real implementation, use `fake` with the
production module:

```elixir
setup do
  DoubleDown.Double.fake(MyApp.Todos, MyApp.Todos.Ecto)
  :ok
end
```

This makes the choice to use the real implementation visible and
intentional, rather than an accident of config inheritance.

## Cross-contract state access

By default, each contract's stateful handler can only see its own
state. This is the right isolation boundary for most tests — you're
testing one contract's logic independently.

However, the "two-contract" pattern (e.g. a `Repo` contract for
writes and a domain-specific `Queries` contract for reads) has two
contracts backed by a single logical store. A Queries handler may
need to see what the Repo handler has written.

4-arity stateful handlers solve this. Instead of receiving just the
contract's own state, they receive a read-only snapshot of all
contract states as a 4th argument:

```elixir
# 3-arity (default) — own state only
fn operation, args, state -> {result, new_state} end

# 4-arity — own state + read-only global snapshot
fn operation, args, state, all_states -> {result, new_state} end
```

The `all_states` map is keyed by contract module:

```elixir
%{
  DoubleDown.Repo => %{User => %{1 => %User{...}}, ...},
  MyApp.Queries => %{...},
  DoubleDown.Contract.GlobalState => true
}
```

The `DoubleDown.Contract.GlobalState` key is a sentinel — if a
handler accidentally returns `all_states` instead of its own state,
the sentinel is detected and a clear error is raised.

**Constraints:**

- The global snapshot is **read-only** — the handler can only update
  its own contract's state via the return value
- The snapshot is taken **before** the `get_and_update` call — it's
  a point-in-time view, not a live reference
- The handler return must be `{result, new_own_state}` — returning
  the global map raises `ArgumentError`

4-arity handlers work with both `DoubleDown.Double.fake/3` and
`DoubleDown.Testing.set_stateful_handler/3`:

```elixir
# With Double.fake — supports expects and stubs alongside the 4-arity fake
MyApp.Queries
|> DoubleDown.Double.fake(
  fn operation, args, state, all_states ->
    repo_state = Map.get(all_states, DoubleDown.Repo, %{})
    # ... query the repo state ...
    {result, state}
  end,
  %{}
)

# With set_stateful_handler — lower-level, no expect/stub support
DoubleDown.Testing.set_stateful_handler(
  MyApp.Queries,
  fn operation, args, state, all_states ->
    {result, state}
  end,
  %{}
)
```

See [Cross-contract state with Repo](repo.md#cross-contract-state-access)
for a worked example of a Queries handler reading the Repo InMemory
store.

## Low-level handler APIs

`DoubleDown.Double` is built on top of `set_stateful_handler`
internally. The low-level handler APIs are still available but
there's probably never a need to use them directly:

- `set_handler(contract, module)` — register a module handler
- `set_fn_handler(contract, fn op, args -> result end)` — register
  a 2-arity function handler
- `set_stateful_handler(contract, fn op, args, state -> {result, state} end, init)` —
  register a 3-arity stateful handler
- `set_stateful_handler(contract, fn op, args, state, all_states -> {result, state} end, init)` —
  register a 4-arity stateful handler with cross-contract state access

These are the primitives that power `Double.stub`, `Double.fake`,
and `Double.expect`.

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

This works because DoubleDown's dispatch resolution checks test
doubles first, then falls back to application config. When using Mox,
the config points to the mock module, and Mox's own process-scoped
expectations provide the isolation.

You can use either approach — DoubleDown's built-in doubles or Mox —
depending on your preference. DoubleDown's doubles don't require
defining mock modules or changing config, and the stateful fake
capability has no Mox equivalent.

---

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Repo >](repo.md)
