# Testing

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Logging >](logging.md)

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
`:static_dispatch?` setting generate inlined direct calls to the
configured implementation — no NimbleOwnership, no `Application.get_env`,
zero dispatch overhead. The test dispatch code path is absent from the
compiled beam files entirely. See
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
per-operation stub. There are three types — **stateless stubs**,
**stateful fakes**, and **module fakes** — each available as a
handler module or a function.

#### Stateless stubs

Stubs provide canned responses without maintaining state. Use
`Double.stub` with a `StubHandler` module or a 2-arity function:

```elixir
# StubHandler module (e.g. Repo.Test)
DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Test)

# StubHandler with a fallback function for reads
DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Test,
  fn
    :get, [User, 1] -> %User{id: 1, name: "Alice"}
    :all, [User] -> [%User{id: 1, name: "Alice"}]
  end
)

# 2-arity function fallback
MyApp.Todos
|> DoubleDown.Double.stub(fn
  :list_todos, [_] -> []
  :get_todo, [id] -> {:ok, %Todo{id: id}}
end)
```

#### Stateful fakes

Fakes maintain in-memory state with atomic updates, enabling
read-after-write consistency. Use `Double.fake` with a `FakeHandler`
module or a 3/4-arity function:

```elixir
# FakeHandler module (e.g. Repo.InMemory)
DoubleDown.Repo
|> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
|> DoubleDown.Double.expect(:insert, fn [changeset] ->
  {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
end)

# With seed data and options
DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory,
  [%User{id: 1, name: "Alice"}],
  fallback_fn: fn :all, [User], state -> Map.values(state[User]) end)

# 3-arity function fake (equivalent to FakeHandler)
DoubleDown.Double.fake(DoubleDown.Repo,
  &DoubleDown.Repo.InMemory.dispatch/3,
  DoubleDown.Repo.InMemory.new())
```

4-arity fakes receive a read-only snapshot of all contract states
for [cross-contract state access](#cross-contract-state-access).

When a 1-arity expect short-circuits (returns an error), the fake
state is unchanged — correct for error simulation. Expects can also
be stateful — see [Stateful expect responders](#stateful-expect-responders).

#### Module fakes (Mimic-style)

A module implementing the contract's `@behaviour`. Override specific
operations with expects while the rest delegate to the module — the
same pattern [Mimic](https://hex.pm/packages/mimic) provides for
plain modules:

```elixir
MyApp.Todos
|> DoubleDown.Double.fake(MyApp.Todos.Ecto)
|> DoubleDown.Double.expect(:create_todo, fn [_] -> {:error, :conflict} end)
```

The module is validated at `fake` time. Module fakes run in the
calling process (via `%Defer{}`), so they work correctly with Ecto
sandbox and other process-scoped resources.

**Important caveat (same as Mimic):** if the module's internal
implementation calls other operations directly, your stubs and
expects won't intercept those internal calls — only calls that go
through the facade are dispatched:

```elixir
# Given this implementation:
defmodule MyApp.Todos.Ecto do
  def create_todo(params) do
    changeset = Todo.changeset(params)
    # This calls insert directly — NOT through the facade
    MyApp.EctoRepo.insert(changeset)
  end
end

# This expect will NOT fire when create_todo calls insert internally:
MyApp.Todos
|> Double.fake(MyApp.Todos.Ecto)
|> Double.expect(:insert, fn [_] -> {:error, :conflict} end)
#                ^^^^^^^ never called — create_todo bypasses the facade

# To make stubs/expects visible to internal calls, the implementation
# must call through the facade:
defmodule MyApp.Todos.Ecto do
  def create_todo(params) do
    changeset = Todo.changeset(params)
    # This goes through dispatch — stubs and expects will intercept it
    MyApp.Todos.insert(changeset)
  end
end
```

#### Dispatch priority

Expects > per-operation stubs > fallback (stub/fake) > raise.
Stubs, stateful fakes, and module fakes are mutually exclusive —
setting one replaces any previous fallback.

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

### Passthrough limitation

`Double.passthrough()` delegates a call to the fake, but it's a
one-way handoff — the expect or stub cannot call the fake *and then*
do something with the result. For example, you can't write "let the
fake insert the record, then modify the returned struct before
giving it back to the caller."

Enabling this would require either chained continuations (awkward
API) or a fundamentally different execution model like algebraic
effects. In practice, the combination of stateful responders
(2-arity expects/stubs that read and write fake state directly) and
conditional passthrough covers most scenarios where you'd want this.

### Cross-contract state access

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

[< Getting Started](getting-started.md) | [Up: README](../README.md) | [Logging >](logging.md)
