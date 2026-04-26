# Phoenix Testing Without a Database

[< Testing](testing.md) | [Up: README](../README.md) | [Repo Test Doubles >](repo-doubles.md)

DoubleDown can power database-free Phoenix controller and LiveView tests
by combining `Phoenix.ConnTest` with in-memory Repo fakes. This gives
you the speed of unit tests with the integration coverage of ConnTests.

## UnitConnCase

The standard Phoenix `ConnCase` uses `Ecto.Adapters.SQL.Sandbox` for
database isolation. For database-free tests, create a `UnitConnCase`
that uses DoubleDown instead:

```elixir
# test/support/unit_conn_case.ex
defmodule MyAppWeb.UnitConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      # Standard Phoenix.ConnTest imports
      import Plug.Conn
      import Phoenix.ConnTest
      import MyAppWeb.ConnCase, only: [build_conn: 0]

      alias MyAppWeb.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint MyAppWeb.Endpoint
    end
  end

  setup do
    # Install the in-memory Repo — every test gets a fresh store
    DoubleDown.Double.fallback(MyApp.Repo, DoubleDown.Repo.InMemory)
    :ok
  end
end
```

If your app uses `DynamicFacade` rather than `ContractFacade` for
the Repo, the setup is the same — `DynamicFacade.setup(MyApp.Repo)`
goes in `test_helper.exs`, and the `UnitConnCase` setup installs the
InMemory fallback:

```elixir
# test/test_helper.exs
DoubleDown.DynamicFacade.setup(MyApp.Repo)
{:ok, _} = DoubleDown.Testing.start()
ExUnit.start()

# test/support/unit_conn_case.ex — same as above
setup do
  DoubleDown.Double.fallback(MyApp.Repo, DoubleDown.Repo.InMemory)
  :ok
end
```

## Writing tests

Use ExMachina factories to build test data, then exercise the
endpoint:

```elixir
defmodule MyAppWeb.OrderControllerTest do
  use MyAppWeb.UnitConnCase

  import MyApp.Factory

  test "GET /orders lists the user's orders", %{conn: conn} do
    user = insert(:user)
    insert(:order, user_id: user.id, status: :active)
    insert(:order, user_id: user.id, status: :cancelled)

    conn = get(conn, "/orders?user_id=#{user.id}")

    assert json_response(conn, 200)["data"] |> length() == 2
  end

  test "POST /orders creates an order", %{conn: conn} do
    user = insert(:user)

    conn = post(conn, "/orders", %{user_id: user.id, item: "Widget"})

    assert %{"id" => _} = json_response(conn, 201)["data"]
  end
end
```

Writes (`insert`, `update`, `delete`) and PK reads (`get`, `get!`)
work out of the box with `Repo.InMemory`. Association preloading
also works.

## Handling Ecto.Query operations

`Repo.InMemory` can't evaluate `Ecto.Query` expressions — it only
handles bare schema queryables. If your controller calls domain
functions that run queries, you have several options:

### Option 1: Stub the query operation

Use a per-operation stub to intercept the specific Repo call:

```elixir
setup do
  DoubleDown.Double.fallback(MyApp.Repo, DoubleDown.Repo.InMemory)
  :ok
end

test "GET /orders filters by status", %{conn: conn} do
  active_order = insert(:order, status: :active)

  # Stub :all to handle the query — InMemory handles everything else
  DoubleDown.Double.stub(MyApp.Repo, :all, fn
    [%Ecto.Query{}] -> [active_order]
    [schema] when is_atom(schema) -> DoubleDown.Double.passthrough()
  end)

  conn = get(conn, "/orders?status=active")

  assert json_response(conn, 200)["data"] |> length() == 1
end
```

### Option 2: Use InMemory with a fallback function

`Repo.InMemory` handles bare-schema reads authoritatively from its
in-memory store. For `Ecto.Query` operations it can't evaluate
natively, it delegates to the `fallback_fn`:

```elixir
setup do
  DoubleDown.Double.fallback(MyApp.Repo, DoubleDown.Repo.InMemory, [],
    fallback_fn: fn
      _contract, :all, [%Ecto.Query{from: %{source: {_, Order}}}], state ->
        state |> Map.get(Order, %{}) |> Map.values()

      _contract, operation, args, _state ->
        raise "Unhandled query: #{operation} #{inspect(args)}"
    end
  )
  :ok
end
```

### Option 3: DynamicFacade on application context modules

Most Phoenix apps already have context modules (`MyApp.Orders`,
`MyApp.Accounts`) that encapsulate Ecto queries. Use
`DynamicFacade.setup/1` on these modules and stub at the context
level — the Ecto queries are completely hidden behind the context
API:

```elixir
# test/test_helper.exs
DoubleDown.DynamicFacade.setup(MyApp.Orders)
DoubleDown.DynamicFacade.setup(MyApp.Accounts)
{:ok, _} = DoubleDown.Testing.start()
ExUnit.start()
```

Then in tests, stub the context functions directly:

```elixir
test "GET /orders lists active orders", %{conn: conn} do
  DoubleDown.Double.fallback(MyApp.Orders, fn
    _contract, :list_active_orders, [user_id] ->
      [%Order{id: 1, user_id: user_id, status: :active}]

    _contract, :get_order!, [id] ->
      %Order{id: id, status: :active}
  end)

  conn = get(conn, "/orders?user_id=42")

  assert json_response(conn, 200)["data"] |> length() == 1
end
```

This is often the cleanest approach for ConnTests because:

- **No Ecto.Query concerns at all** — the queries live inside the
  context module, and DynamicFacade intercepts at the function level
- **Tests match the controller's actual call pattern** — if the
  controller calls `Orders.list_active_orders(user_id)`, the test
  stubs exactly that
- **No new modules needed** — DynamicFacade works on your existing
  context modules
- **Tests that don't install a handler** get the real context
  implementation automatically

You can mix this with Repo-level InMemory for write operations:

```elixir
setup do
  # InMemory Repo for writes (insert, update, delete)
  DoubleDown.Double.fallback(MyApp.Repo, DoubleDown.Repo.InMemory)
  # Context-level stubs for query-heavy reads
  DoubleDown.Double.fallback(MyApp.Orders, fn _contract, op, args ->
    case {op, args} do
      {:list_active_orders, [_]} -> []
      {:count_orders, [_]} -> 0
    end
  end)
  :ok
end
```

### Option 4: Contract boundary above Repo

If your domain logic is behind a DoubleDown contract (e.g.
`MyApp.Orders` with `defcallback`), stub at that level instead of
at the Repo level:

```elixir
setup do
  DoubleDown.Double.fallback(MyApp.Orders, fn _contract, operation, args ->
    case {operation, args} do
      {:list_active_orders, [user_id]} ->
        [%Order{user_id: user_id, status: :active}]

      {:create_order, [params]} ->
        {:ok, struct!(Order, params)}
    end
  end)
  :ok
end
```

This is the cleanest approach — the test doesn't need to know about
Ecto queries at all. It stubs the domain contract and the controller
calls flow through naturally.

### Option 5: Expect specific calls

For tests that need to verify specific operations were called:

```elixir
test "POST /orders calls create_order exactly once", %{conn: conn} do
  user = insert(:user)

  DoubleDown.Double.expect(MyApp.Orders, :create_order, fn [params] ->
    assert params.user_id == user.id
    {:ok, struct!(Order, params)}
  end)

  post(conn, "/orders", %{user_id: user.id, item: "Widget"})

  DoubleDown.Double.verify!()
end
```

## When to use UnitConnCase vs ConnCase

| Aspect | `ConnCase` (DB) | `UnitConnCase` (DoubleDown) |
|--------|----------------|----------------------------|
| **Speed** | Slower (DB I/O) | Fast (in-memory) |
| **Ecto.Query** | Full support | Needs stubs for queries |
| **Read-after-write** | Full support | Full support (InMemory) |
| **Transactions** | Real ACID | In-memory with rollback |
| **ExMachina** | Works | Works |
| **Async** | Via Sandbox | Via NimbleOwnership |
| **Best for** | Integration tests, complex queries | Controller logic, JSON serialization, auth, error handling |

Use `UnitConnCase` when you're testing controller/LiveView logic
(parameter handling, authorization, response formatting) and the
domain operations can be stubbed. Use `ConnCase` when you need full
database fidelity (complex joins, constraint validation, migrations).

Many projects use both — `UnitConnCase` for the majority of endpoint
tests (fast feedback) and `ConnCase` for a smaller set of
integration tests that exercise the full stack.

---

[< Testing](testing.md) | [Up: README](../README.md) | [Repo Test Doubles >](repo-doubles.md)
