# Incremental Migration

[< Repo Testing](repo-testing.md) | [Up: README](../README.md)

This guide covers adopting DoubleDown into an existing Elixir/Phoenix
codebase alongside direct Ecto.Repo calls. You don't need to migrate
everything at once — the two styles coexist cleanly.

## Strategy: new code first

The highest-impact, lowest-risk approach is:

1. **Don't migrate existing tests.** They work, they have value, leave
   them on the Ecto sandbox.
2. **Write new domain logic behind contracts.** New contexts,
   new features, new orchestration functions.
3. **Migrate existing code opportunistically.** When you're already
   changing a function, wrap it in a contract boundary.

This means your test suite gradually shifts from slow DB-backed tests
to fast in-memory tests as new code accumulates — without any
big-bang migration.

## The two-contract pattern

Most domain logic interacts with the database in two ways:

1. **Generic Repo operations** — `insert`, `update`, `delete`, `get`,
   `transact`. These are the same across all features.
2. **Domain-specific queries** — "find active users with overdue
   invoices", "get the latest shift for this employee". These are
   unique to each feature.

DoubleDown handles these with two contracts:

- **`DoubleDown.Repo`** — ships with DoubleDown, covers all
  generic Repo operations. One facade per app, shared by all features.
- **A per-feature Queries contract** — you define this with `defcallback`
  for each feature's domain-specific reads.

### Example: wrapping a context function

Suppose you have a `Billing.create_invoice/1` function that:

1. Validates params and builds a changeset
2. Looks up the customer's payment method
3. Inserts the invoice
4. Inserts line items

**Step 1: Create a Repo facade** (once per app)

```elixir
defmodule MyApp.Repo do
  use DoubleDown.ContractFacade, contract: DoubleDown.Repo, otp_app: :my_app
end
```

```elixir
# config/config.exs
config :my_app, DoubleDown.Repo, impl: MyApp.EctoRepo

# config/test.exs
config :my_app, DoubleDown.Repo, impl: nil
```

**Step 2: Define a Queries contract** for the domain reads

```elixir
defmodule MyApp.Billing.Queries do
  use DoubleDown.ContractFacade, otp_app: :my_app

  defcallback get_payment_method(customer_id :: integer()) ::
    {:ok, PaymentMethod.t()} | {:error, :not_found}
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Billing.Queries, impl: MyApp.Billing.Queries.Ecto

# config/test.exs
config :my_app, MyApp.Billing.Queries, impl: nil
```

**Step 3: Implement the Ecto adapter** for Queries

```elixir
defmodule MyApp.Billing.Queries.Ecto do
  @behaviour MyApp.Billing.Queries

  @impl true
  def get_payment_method(customer_id) do
    case MyApp.EctoRepo.get_by(PaymentMethod, customer_id: customer_id) do
      nil -> {:error, :not_found}
      pm -> {:ok, pm}
    end
  end
end
```

**Step 4: Write the domain function** using both contracts

```elixir
defmodule MyApp.Billing do
  alias MyApp.Repo
  alias MyApp.Billing.Queries

  def create_invoice(params) do
    Repo.transact(fn ->
      with {:ok, pm} <- Queries.get_payment_method(params.customer_id),
           {:ok, invoice} <- Repo.insert(Invoice.changeset(params, pm)),
           {:ok, _items} <- insert_line_items(invoice, params.items) do
        {:ok, invoice}
      end
    end, [])
  end

  defp insert_line_items(invoice, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case Repo.insert(LineItem.changeset(invoice, item)) do
        {:ok, li} -> {:cont, {:ok, [li | acc]}}
        {:error, cs} -> {:halt, {:error, cs}}
      end
    end)
  end
end
```

**Step 5: Test without a database**

```elixir
defmodule MyApp.BillingTest do
  use ExUnit.Case, async: true

  alias MyApp.Billing.Queries

  setup do
    # Queries — stub domain-specific reads
    DoubleDown.Double.stub(Queries, :get_payment_method, fn [_customer_id] ->
      {:ok, %PaymentMethod{id: 1, type: :card}}
    end)

    # Repo — stateless writes via Repo.Stub stub
    DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Stub)

    :ok
  end

  test "create_invoice inserts invoice and line items" do
    DoubleDown.Testing.enable_log(DoubleDown.Repo)

    assert {:ok, %Invoice{}} =
      MyApp.Billing.create_invoice(%{
        customer_id: 1,
        items: [%{description: "Widget", amount: 100}]
      })

    log = DoubleDown.Testing.get_log(DoubleDown.Repo)
    operations = Enum.map(log, fn {_, op, _, _} -> op end)
    assert :insert in operations
  end
end
```

This test runs in < 1ms. No database, no sandbox, no factories.

## Coexisting with direct Ecto.Repo calls

Code that hasn't been migrated continues to call `MyApp.EctoRepo`
directly. Code behind contract boundaries calls `MyApp.Repo` (the
facade). Both work in the same application — there's no conflict.

In tests:

- **Migrated code** uses `DoubleDown.Double` (expect/stub/fake)
  — no DB needed, `async: true`
- **Unmigrated code** uses `Ecto.Adapters.SQL.Sandbox` as before

The two can even coexist in the same test if needed (e.g., an
integration test that uses the real DB for some operations and
stubs others).

## The fail-fast pattern

Set `impl: nil` in `config/test.exs` for every contract:

```elixir
# config/test.exs
config :my_app, DoubleDown.Repo, impl: nil
config :my_app, MyApp.Billing.Queries, impl: nil
```

This ensures any test that forgets to set up a double gets an
immediate error instead of silently hitting the real implementation.
For integration tests that intentionally use the real DB, use `fake`
with the production module:

```elixir
DoubleDown.Double.fake(DoubleDown.Repo, MyApp.EctoRepo)
```

## Choosing a Repo fake

- **`Repo.InMemory`** (recommended) — closed-world stateful fake.
  The state is the complete truth — all bare-schema reads work
  without a fallback. Use this for most tests, especially with
  ExMachina factories.
- **`Repo.OpenInMemory`** — open-world stateful fake. The state may
  be incomplete — reads for missing records fall through to a
  fallback function. Use when you need fine-grained control over
  which reads come from state vs fallback.
- **`Repo.Stub`** — stateless stub. Writes succeed but store
  nothing. No read-after-write. Fastest setup — use for simple
  command-style functions that just write and return.

## What stays on the DB

Some things should remain as integration tests against a real database:

- **Query correctness** — `from u in User, where: u.age > 21` can't
  be evaluated in memory. Test these via the Ecto adapter.
- **Constraint validation** — unique indexes, foreign keys, check
  constraints.
- **Transaction isolation** — rollback behaviour, concurrent writes.
- **Migration testing** — schema changes against a real DB.
- **End-to-end flows** — API → context → DB → response.

The goal isn't to eliminate DB tests — it's to ensure that the tests
which don't *need* a DB don't *use* a DB.

---

[< Repo Testing](repo-testing.md) | [Up: README](../README.md)
