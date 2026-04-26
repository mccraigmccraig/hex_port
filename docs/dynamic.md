# Dynamic Facades

[< Testing](testing.md) | [Up: README](../README.md) | [Logging >](logging.md)

Dynamic facades enable Mimic-style bytecode interception — replace
any module with a dispatch shim at test time, then use the full
`DoubleDown.Double` API without defining an explicit contract or
facade. The shimmed module becomes both the **contract** (the name
used in test double setup) and the **facade** (what callers use).

## When to use dynamic facades

| Scenario | Approach |
|----------|----------|
| New code, long-term boundary | Contract-based (`defcallback` + `DoubleDown.ContractFacade`) |
| Existing `@behaviour` you don't control | `DoubleDown.BehaviourFacade` |
| Legacy code without contracts or behaviours | **Dynamic facade** |
| Third-party modules with no behaviour | **Dynamic facade** |
| Quick prototyping | **Dynamic facade**, graduate to contract-based later |

Dynamic facades trade compile-time safety (typespecs, LSP docs,
spec mismatch detection) for zero-ceremony setup. Both approaches
use the same dispatch and Double infrastructure — they coexist in
the same test suite.

## Setup

Call `DynamicFacade.setup/1` in `test/test_helper.exs` **before**
`ExUnit.start()`:

```elixir
# test/test_helper.exs
DoubleDown.DynamicFacade.setup(MyApp.EctoRepo)
DoubleDown.DynamicFacade.setup(SomeThirdPartyClient)

ExUnit.start()
{:ok, _} = DoubleDown.Testing.start()
```

`setup/1` copies the original module to a backup
(`Module.__dd_original__`) and replaces it with a dispatch shim.
The original module name becomes the implicit contract — use it
as the first argument to all `Double` API calls:

```elixir
# MyApp.EctoRepo is the contract — same module callers use
DoubleDown.Double.fallback(MyApp.EctoRepo, DoubleDown.Repo.InMemory)
DoubleDown.Double.fallback(SomeThirdPartyClient, fn :fetch, [id] -> {:ok, id} end)
```

The shim checks NimbleOwnership for test handlers, falling back to
the original implementation when none are installed. Bytecode
replacement is VM-global — it must happen before any tests run.
Tests that don't install a handler get the original module's
behaviour automatically.

## Using Double APIs

After setup, the full `DoubleDown.Double` API works with the
dynamic module — expects, stubs, fakes, passthrough, stateful
responders, cross-contract state access, dispatch logging:

```elixir
setup do
  # Stateful fake
  DoubleDown.Double.fallback(MyApp.EctoRepo, DoubleDown.Repo.InMemory)
  :ok
end

test "insert then get" do
  {:ok, user} = MyApp.EctoRepo.insert(User.changeset(%{name: "Alice"}))
  assert ^user = MyApp.EctoRepo.get(User, user.id)
end
```

### Stubs

```elixir
# Function stub
DoubleDown.Double.fallback(SomeClient, fn _contract, operation, args ->
  case {operation, args} do
    {:fetch, [id]} -> {:ok, %{id: id}}
    {:list, []} -> []
  end
end)

# Per-operation stub
DoubleDown.Double.stub(SomeClient, :fetch, fn [id] -> {:ok, %{id: id}} end)
```

### Expects

```elixir
DoubleDown.Double.expect(SomeClient, :fetch, fn [_] -> {:error, :timeout} end)

# With passthrough — delegates to the original module
DoubleDown.Double.expect(SomeClient, :fetch, :passthrough)

# Stateful expect (requires a fake)
DoubleDown.Double.expect(SomeClient, :fetch, fn [id], state ->
  {Map.get(state, id), state}
end)
```

### Override one operation, delegate the rest

Use `Double.dynamic/1` to set up the original module as the
fallback, then layer expects on top:

```elixir
SomeClient
|> DoubleDown.Double.dynamic()
|> DoubleDown.Double.expect(:fetch, fn [_] -> {:error, :not_found} end)

# fetch is overridden, all other functions delegate to the original
```

## Passthrough to original

When no test handler is installed, the dynamic shim automatically
falls back to the original module. This means unrelated tests are
completely unaffected.

When a handler IS installed, `Double.passthrough()` and
`:passthrough` expects delegate to the fallback (fake, stub, or
module fake) — not directly to the original. To delegate to the
original explicitly, use `Double.dynamic/1`:

```elixir
SomeClient
|> DoubleDown.Double.dynamic()
|> DoubleDown.Double.expect(:fetch, :passthrough)
```

## Cross-contract state access

Dynamic facades participate in cross-contract state access. A
4-arity handler on a dynamic module can read state from
contract-based facades, and vice versa:

```elixir
# Contract-based Repo with InMemory
DoubleDown.Double.fallback(DoubleDown.Repo, DoubleDown.Repo.InMemory)

# Dynamic module reads Repo state
DoubleDown.Double.fallback(MyApp.Legacy,
  fn :check_user, [id], state, all_states ->
    repo_state = Map.get(all_states, DoubleDown.Repo, %{})
    users = repo_state |> Map.get(User, %{}) |> Map.values()
    {Enum.any?(users, &(&1.id == id)), state}
  end,
  %{}
)
```

## Guardrails

`DynamicFacade.setup/1` refuses to set up facades for:

- **DoubleDown contract modules** — use `DoubleDown.ContractFacade` instead
- **DoubleDown internal modules** — would break the dispatch machinery
- **NimbleOwnership** — required by dispatch
- **Erlang/OTP modules** — would be catastrophic

## Comparison of facade types

See [Choosing a facade type](getting-started.md#choosing-a-facade-type)
for a full feature comparison table across `ContractFacade`,
`BehaviourFacade`, and `DynamicFacade`.

## Migration path

Start with dynamic facades for quick wins, then graduate to
typed facades for boundaries you want to keep long-term:

1. `DynamicFacade.setup(MyModule)` in test_helper.exs
2. Write tests using Double APIs
3. When the boundary stabilises, choose your facade type:
   - If the module already defines `@callback` declarations,
     use `DoubleDown.BehaviourFacade`
   - Otherwise, define a `defcallback` contract and use
     `DoubleDown.ContractFacade`
4. Remove the `DynamicFacade.setup` call

---

[< Testing](testing.md) | [Up: README](../README.md) | [Logging >](logging.md)
