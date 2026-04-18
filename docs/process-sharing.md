# Process Sharing

[< Logging](logging.md) | [Up: README](../README.md) | [Repo >](repo.md)

All test doubles are process-scoped. `async: true` tests run in full
isolation — each test process has its own doubles, state, and logs.

## Task.async children

**Task.async children** automatically inherit their parent's doubles
via the `$callers` chain. No setup needed.

## Explicit sharing with `allow`

**Other processes** (plain `spawn`, Agent, GenServer) need explicit
sharing:

```elixir
DoubleDown.Double.allow(MyApp.Todos, self(), agent_pid)
```

`allow/3` also accepts a lazy pid function for processes that don't
exist yet at setup time:

```elixir
DoubleDown.Double.allow(MyApp.Todos, fn -> GenServer.whereis(MyWorker) end)
```

## Global mode

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

## Choosing the right approach

| Situation | Approach | `async: true`? |
|-----------|----------|----------------|
| Direct function calls | No extra setup needed | Yes |
| `Task.async` / `Task.Supervisor` | Automatic via `$callers` | Yes |
| Known pid (Agent, named GenServer) | `allow/3` with the pid | Yes |
| Pid not known at setup time | `allow/3` with lazy fn | Yes |
| Supervision tree / Broadway / Oban | `set_mode_to_global/0` | **No** |

## Example: testing a GenServer that dispatches through a contract

```elixir
defmodule MyApp.WorkerTest do
  use ExUnit.Case, async: true

  setup do
    MyApp.Todos
    |> DoubleDown.Double.stub(:get_todo, fn [id] -> {:ok, %Todo{id: id}} end)

    {:ok, pid} = MyApp.Worker.start_link([])
    DoubleDown.Double.allow(MyApp.Todos, self(), pid)

    %{worker: pid}
  end

  test "worker fetches todo via contract", %{worker: pid} do
    assert {:ok, %Todo{id: "42"}} = MyApp.Worker.fetch(pid, "42")
  end
end
```

## Example: testing through a supervision tree

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

---

[< Logging](logging.md) | [Up: README](../README.md) | [Repo >](repo.md)
