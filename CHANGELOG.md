# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.49.0]

### Added

- **`DoubleDown.Repo` `:transaction` operation.** Added `transaction/1,2`
  to the Repo contract as an alias for `transact/1,2`, matching the
  standard `Ecto.Repo.transaction` name. Dispatched through all three
  Repo doubles (InMemory, OpenInMemory, Stub).

- **`DoubleDown.Contract.Dispatch.Keys` module.** Centralised
  NimbleOwnership key helpers (`ownership_server/0`, `log_key/1`,
  `contracts_key/0`). Eliminates duplicated `@ownership_server` module
  attributes and scattered `Module.concat` calls across Dispatch,
  Double, and Testing.

- **`DoubleDown.Contract.Dispatch.HandlerMeta` structs.**
  `HandlerMeta.Module`, `HandlerMeta.Fn`, `HandlerMeta.Stateful` —
  typed structs replacing the loose maps that described handler types.
  Pattern matching on struct name replaces the `:type` discriminator key.

- **`DoubleDown.Double.CanonicalHandlerState` struct.** Replaces the
  loose `@initial_state` map with a typed struct. `new/1` constructor
  ensures the `:contract` field is never nil. `@enforce_keys [:contract]`.

- **Handler overwrite protection.** `Testing.set_*_handler` now raises
  `ArgumentError` if a handler is already installed for the contract.
  Call `Testing.reset()` first to clear all handlers before reinstalling.
  Prevents accidental silent overwrites and mixing of Double/Testing APIs.

- **Double/Testing API mixing guards.** `Double.ensure_handler_installed`
  raises if a non-Double handler is already installed. `Testing.set_meta`
  raises if any handler already exists. Clear error messages direct users
  to use one API exclusively or call `reset()` first.

- **Per-operation fakes.** `Double.fake(contract, :operation, fn [args], state -> {result, new_state} end)`
  installs a permanent stateful override for a single operation,
  reading and writing the fallback fake's state. Requires a stateful
  fallback fake to be installed first. Replaces the removed "stateful
  stubs" with the correct abstraction — per-op fakes are fakes
  (stateful, real logic), not stubs (stateless, canned values).
  Dispatch priority: expects > per-op fakes > per-op stubs > fallback > raise.

### Changed

- **Breaking: fn handler signature changed from 2-arity to 3-arity.**
  `set_fn_handler`, `Double.stub` function fallbacks, and
  `StubHandler.new` callbacks now use `fn contract, operation, args -> result end`
  instead of `fn operation, args -> result end`. This makes fn handlers
  symmetrical with stateful handlers, which already receive contract as
  the first argument. `Repo.Stub` updated to return 3-arity fns and
  accept 3-arity fallback functions.

- **Breaking: stateful per-operation stubs removed.** `Double.stub/3`
  now only accepts 1-arity (stateless) fns. The 2-arity and 3-arity
  "stateful stub" variants were conceptually confused — stubs that
  mutate state are really per-operation fakes. For stateful per-op
  overrides, use `expect/4` with a 2/3-arity responder, or handle the
  logic in the fallback fake's dispatch function.

- **Stateful handler state unified under contract key.** Handler state
  is now stored inline in `HandlerMeta.Stateful.state` instead of under
  a separate NimbleOwnership key. One contract = one NimbleOwnership key.
  Eliminates a redundant IPC round-trip (`GenServer.call`) on every
  stateful dispatch. `Keys.state_key/1` removed.

- **Dispatch pattern matching uses structs.** `invoke_handler` matches
  on `%HandlerMeta.Module{}`, `%HandlerMeta.Fn{}`,
  `%HandlerMeta.Stateful{}` instead of `%{type: :module, ...}` maps.
  `get_state`/`restore_state`/`build_global_state` match on
  `%CanonicalHandlerState{}` instead of checking for `:fallback_state`
  key presence — unforgeable struct match vs fragile key-presence check.

### Improved

- **No-handler error message** now mentions the recommended `Double.*`
  API (`Double.fake`, `Double.stub`, `Double.expect`) first, with the
  lower-level `Testing.*` API as an alternative.

- **`canonical_handler/5`** now has a `%CanonicalHandlerState{}` guard
  on the state parameter and a comment explaining why the contract
  parameter is unused (available via `state.contract`).

## [0.48.1]

### Fixed

- Code formatting.
- Documentation updated with complete operation tables for all Repo
  doubles and current installation version.

## [0.48.0]

### Added

- **Repo API expansion.** Six new operations added to `DoubleDown.Repo`
  contract and both InMemory fakes (`Repo.InMemory`, `Repo.OpenInMemory`):

  - `insert_or_update/1,2` and `insert_or_update!/1,2` — checks
    `Ecto.get_meta(changeset.data, :state)` to delegate to insert or
    update. Fully authoritative in both fakes.
  - `reload/1,2` and `reload!/1,2` — re-fetches by PK from the store.
    Handles single structs and lists. `reload!` raises on not-found.
  - `preload/2,3` — resolves associations from the in-memory store
    using Ecto schema reflection (`__schema__(:association, name)`).
    Supports `has_many`, `has_one`, `belongs_to`, `many_to_many`
    (when join schema is in store), `has_through` (by chaining),
    nested preloads, list-of-structs, and static `where` clauses on
    associations. New module `DoubleDown.Repo.Impl.Preloader`.
  - `all_by/2,3` — scan-and-filter like `get_by` but returns all
    matching records as a list. New in Ecto 3.13.
  - `load/2` — stateless coercion of raw data into a schema struct
    via `Ecto.Schema.Loader.unsafe_load`. Supports map, keyword list,
    and `{columns, values}` tuple inputs.
  - `in_transaction?/0` — reads the process dictionary flag already
    used by `transact`/`rollback`. Returns boolean.

- **`stream/1,2` added to `DoubleDown.Repo` contract.** Core Ecto
  API for lazily enumerating query results. Cannot be evaluated in
  memory — all adapters delegate to fallback.

- **8 missing dispatch clauses added to `Repo.Stub`.** `insert_or_update`,
  `insert_or_update!`, `load`, `in_transaction?`, `preload`, `reload`,
  `reload!`, `all_by` — all with opts-stripping variants. `in_transaction?`
  uses a Defer-wrapped process dict check. `load` is handled statelessly.
  Fallback operations (`preload`, `reload`, `reload!`, `all_by`, `stream`)
  produce helpful error messages when no fallback is registered.

- **`insert_all` `returning:` now supports field lists.** `returning: [:id, :name]`
  returns maps containing only those fields, matching Ecto adapter
  behaviour. `returning: true` still returns full structs.

- **Catch-all dispatch clause** added to both `Repo.InMemory` and
  `Repo.OpenInMemory`. Unrecognised operations now delegate to the
  fallback function with a helpful error instead of raising
  `FunctionClauseError`.

- **`query`/`query!` dispatch clauses** added to `Repo.InMemory` and
  `Repo.OpenInMemory`. Raw SQL operations delegate to fallback with
  a clear "register a fallback" error message.

- **`ContractFacade` preserves user `@moduledoc`.** User-provided
  `@moduledoc` is now combined with the generated dispatch info
  (user text first, generated appended after a separator).
  `@moduledoc false` suppresses all documentation.

### Changed

- **Minimum Elixir version relaxed from `~> 1.19` to `~> 1.14`.**
  No 1.15+ features are used. Floor driven by `ecto ~> 3.12`.

- **`verify!/0` returns `:ok` when no Double handlers installed.**
  Previously raised a confusing error. If no `Double`-managed handlers
  were installed there are no expectations to verify, so verification
  trivially passes.

- **`insert_all` with binary table name sources** now raises a
  descriptive error explaining that InMemory requires atom schema
  modules, suggesting `fallback_fn` or `Double.expect`.

### Fixed

- **InMemory insert/update now sets meta state to `:loaded`** on
  returned structs, matching real `Ecto.Repo` behaviour. Previously
  returned structs with `:built` state, which caused `insert_or_update`
  to misclassify already-persisted records as new.

- **`dispatch_delete!` now raises `Ecto.InvalidChangesetError`** on
  invalid changesets, matching `dispatch_insert!` and `dispatch_update!`.
  Previously raised `MatchError`.

- **`get_state/1` resolves owner through `$callers` chain.** Previously
  used raw `self()`, returning `nil` from child processes (e.g.
  `Task.async`). Now uses the same owner resolution as
  `resolve_test_handler/1`. Extracted shared `resolve_owner_pid/1`
  utility.

- **OpenInMemory `fallback_fn` docs corrected** from 3-arity
  `(operation, args, state)` to 4-arity `(contract, operation, args, state)`.

### Removed

- **Stale `DoubleDown.Facade` and `DoubleDown.Dynamic` modules deleted.**
  These were pre-rename duplicates of `DoubleDown.ContractFacade` and
  `DoubleDown.DynamicFacade` with separate registries. No code referenced
  them.

### Improved

- **`rename_module_attribute/2`** — added empty list base case for
  defensive termination.

- **`resolve_fake_dispatch/1`** — added `cond` fallback raising a
  clear `ArgumentError` instead of `CondClauseError`.

- **`create_shim/2`** — compiler options toggle wrapped in `try/after`
  so `ignore_module_conflict` is always restored.

- **`insert_all` limitations documented** in `Repo.InMemory` moduledoc:
  `on_conflict`/`conflict_target` are silently ignored (constraint
  testing requires a real database), binary table name sources are
  not supported.

- **`FunctionClauseError` rescue limitation documented** in
  `DoubleDown.Double` moduledoc. If a fallback body internally raises
  `FunctionClauseError`, it is misreported as "Unexpected call" — a
  known Mox-shared limitation.

- **Stale "X.Port" placeholder fixed** in `Testing.enable_log/1` doc.

- **`test_helper.exs` reordered** — `DoubleDown.Testing.start()` now
  called before `ExUnit.start()`, matching documented guidance.

- **Internals doc group expanded** — `Autogenerate`, `EctoParity`,
  `InMemoryShared`, `Preloader` added to the Internals group in
  `mix.exs` so they appear in hexdocs.

- **`DoubleDown.Repo` moduledoc** now explains relationship to
  `Ecto.Repo` — why it's a DoubleDown contract not an Ecto behaviour,
  `transact` vs `transaction` naming, and which callbacks are
  intentionally excluded.

- **OpenInMemory bulk ops documented** — clarified that `insert_all`,
  `update_all`, `delete_all` always delegate to fallback and do not
  mutate in-memory state (unlike InMemory).

- **Test coverage:** `insert_or_update!` opts-accepting 2-arity variant
  tested through InMemory and OpenInMemory.

- **TOCTOU race in `DynamicFacade.register_module/1` documented** —
  harmless in practice since `setup/1` is called sequentially in
  `test_helper.exs`.

- **`InMemoryShared.new/2` disambiguation documented** — inline
  comments explain how the legacy keyword-only form is distinguished
  from the positional seed-list form.

## [0.47.2]

### Added

- `DoubleDown.Contract.Dispatch.handler_active?/1` — public boolean API
  to check whether the calling process has a test handler installed for
  a given contract module. Returns `true` when a handler is active (via
  `Double.fake/2`, `expect/3`, etc.), `false` otherwise. Respects the
  `$callers` chain. Useful for test infrastructure that needs to skip
  real-DB side-effects (e.g. Carbonite session variables) when an
  in-memory handler is intercepting Repo calls.

## [0.47.1]

### Fixed

- Code formatting.

## [0.47.0]

### Fixed

- **Transaction rollback now covers all failure paths.** `run_in_transaction`
  restores pre-transaction state on `{:error, _}` returns, raised exceptions
  (re-raised after restore), and failed `Ecto.Multi` tuples — not just
  explicit `Repo.rollback/1` calls. Previously, error branches left
  partially-mutated fake state. (GitHub #1)

- **`restore_state` uses correct owner pid.** `restore_state/3` now accepts
  `owner_pid` as an explicit parameter, resolved via `resolve_test_handler`
  at rollback time. Transactions run inside a `Task` now correctly restore
  state to the owning test process instead of silently no-oping. (GitHub #1)

- **`Ecto.Multi` bulk ops now execute instead of returning `{0, nil}`.**
  `MultiStepper` routes `insert_all`, `update_all`, and `delete_all` steps
  through `repo_facade` — each fake's own dispatch handles state mutation.
  Previously these were hardcoded no-ops. (GitHub #2)

- **`insert_all` raises for missing non-autogenerated PKs.** When
  `maybe_autogenerate_id` returns an error for a schema without
  autogeneration, `insert_all` now raises `ArgumentError` — matching
  single-row `insert` behaviour. Previously the error was swallowed and
  rows collapsed onto a nil key. (GitHub #3)

- **`@primary_key false` schemas support multiple rows.** No-PK schemas
  are now stored as lists (reverse insertion order) instead of a
  `%{nil => record}` map. All store accessors (`put_record`, `get_record`,
  `delete_record`, `records_for_schema`) and bulk ops (`delete_all`,
  `update_all`) handle the dual map/list representation. (GitHub #4)

- **`get_by!` raises `Ecto.NoResultsError` when PK matches but extra
  clauses don't.** Previously returned `nil` for both `get_by` and
  `get_by!` in this case, diverging from real Ecto. (GitHub #5)

- **`rollback/1` outside a transaction raises `RuntimeError`.** Uses a
  process dictionary flag set by `run_in_transaction` and cleared via
  `try/after`. Both `InMemoryShared` and `Stub` updated. Previously
  an uncaught `throw({:rollback, _})` surfaced. (GitHub #6)

### Changed

- **Breaking:** All handler function signatures gained `contract` as the
  first parameter. This affects `FakeHandler.dispatch` (`/3` → `/4`,
  `/4` → `/5`), `set_stateful_handler` fns (3-arity → 4-arity,
  4-arity → 5-arity), `fallback_fn` (3-arity → 4-arity), and
  `restore_state` (`/2` → `/3`). The contract module now flows through
  the entire handler chain — `invoke_handler`, `canonical_handler`,
  `dispatch_via_fallback`, `try_fallback` — eliminating the hardcoded
  `DoubleDown.Repo` in transaction rollback. Enables handlers to know
  which contract they are serving.

## [0.46.3]

### Fixed

- FK backfill now recursively inserts parent structs when the
  parent's PK is nil. This fixes the ExMachina pattern where
  `build(:parent)` produces a struct with nil PK that hasn't been
  inserted yet — matching real Ecto.Repo behaviour of recursively
  inserting `belongs_to` parents before the child.

## [0.46.2]

### Fixed

- Added test coverage for FK backfill with parent struct returned
  from a prior insert (the exact ExMachina factory pattern). Confirms
  backfill correctly uses `related_key` from association metadata,
  not a hardcoded `:id` field.

## [0.46.1]

### Fixed

- FK backfill now explicitly skips `%Ecto.Association.NotLoaded{}`
  associations rather than relying on `Map.get` returning nil.
  Defensive fix for a reported FK backfill failure via the ExMachina
  `insert!` path.

- Added integration test for `insert!` bare struct through the
  `Double.fake` facade dispatch path to verify FK backfill works
  end-to-end.

## [0.46.0]

### Added

- `query/1,2,3` and `query!/1,2,3` added to `DoubleDown.Repo`
  contract. Raw SQL operations from ecto_sql — adding them to the
  contract makes them interceptable via expects/stubs so code paths
  that call `Repo.query!` can be tested without a database.

- FK backfill on insert. When inserting a struct with a loaded
  `belongs_to` association but a nil FK field, InMemory now copies
  the parent's PK into the FK field — matching real Ecto.Repo
  behaviour. Makes ExMachina factories work transparently:
  `insert(:child, parent: parent)` automatically sets the FK.
  Implemented in `Repo.Impl.EctoParity.backfill_foreign_keys/1`.

- Association fields are reset to `%Ecto.Association.NotLoaded{}`
  on insert, matching real Ecto.Repo behaviour. Struct equality
  comparisons between `insert(:thing)` and `Repo.get!(Thing, id)`
  now work without comparing individual fields. Implemented in
  `Repo.Impl.EctoParity.reset_associations/1`. Runs after FK
  backfill (which needs the loaded association to extract the FK).

- `Repo.Impl.EctoParity` — new module for Ecto schema-introspection
  concerns that make the in-memory fakes behave more like real Ecto.

### Changed

- InMemory's `get!`, `get_by!`, `one!` now raise
  `Ecto.NoResultsError` (was `ArgumentError`). `one`, `one!`,
  `get_by!` now raise `Ecto.MultipleResultsError` when multiple
  records match (was `ArgumentError`). Matches real Ecto.Repo
  behaviour so tests with `assert_raise Ecto.NoResultsError` work
  without modification.

## [0.45.0]

### Added

- In-memory transaction rollback support. `rollback/1` in the
  stateful test adapters (`Repo.InMemory` and `Repo.OpenInMemory`)
  now restores the store to its pre-transaction state — inserts,
  updates, and deletes within a rolled-back transaction are undone.

  Implemented by snapshotting the store at `transact` start and
  restoring via `Contract.Dispatch.restore_state/2` on rollback.
  Only the Repo contract's state is restored; other contracts are
  unaffected.

- `DoubleDown.Contract.Dispatch.get_state/1` — read the current
  domain state for a contract. Returns `fallback_state` for
  Double-managed handlers, raw state for `set_stateful_handler`.

- `DoubleDown.Contract.Dispatch.restore_state/2` — replace a single
  contract's state in NimbleOwnership, leaving the handler function
  and all other contracts' state untouched. Scoped to a single
  contract by design.

## [0.44.0]

### Added

- Bang write operations: `insert!/1,2`, `update!/1,2`, `delete!/1,2`
  added to `DoubleDown.Repo` contract and all three test doubles.
  These were lost when auto-bang generation was removed in v0.38.0.
  Needed for ExMachina integration (`ExMachina` calls `Repo.insert!`).

- `insert`/`insert!` now accept bare structs in addition to
  changesets, matching `Ecto.Repo` behaviour. `delete`/`delete!`
  now accept changesets in addition to structs.

- ExMachina integration tests demonstrating the factory + InMemory
  pattern: factory-inserted records readable via `all`, `get`,
  `get_by`, `exists?`, `aggregate` — no database, `async: true`,
  at in-memory speed. `ex_machina ~> 2.7` added as a test-only
  dependency.

- ExMachina integration documentation in `docs/repo.md` with
  worked example: factory definition, test setup, reads, aggregates,
  read-after-write, failure simulation. Cross-referenced from
  `docs/getting-started.md`.

### Changed

- **Breaking:** `DoubleDown.Repo.Port` (test facade) renamed to
  `DoubleDown.Test.Repo`. Natural alias gives `Repo.*` without
  `as:` clause.

## [0.43.0]

### Changed

- **Breaking:** `DoubleDown.Facade` renamed to `DoubleDown.ContractFacade`.
  Symmetric `<qualifier>Facade` naming across all three facade builders:
  `ContractFacade`, `BehaviourFacade`, `DynamicFacade`.

- **Breaking:** `DoubleDown.Dynamic` renamed to `DoubleDown.DynamicFacade`.

- **Breaking:** `DoubleDown.Dispatch` renamed to
  `DoubleDown.Contract.Dispatch`. The dispatch machinery is keyed by
  contract module and belongs under Contract, not at the top level.
  Child modules (`Defer`, `FakeHandler`, `StubHandler`, `Passthrough`)
  moved accordingly. Moved to "Internals" doc group.

- **Breaking:** `DoubleDown.Repo.Test` renamed to `DoubleDown.Repo.Stub`.
  The name now communicates what the module is — a stateless stub —
  matching the test-double taxonomy (stub/mock/fake).

- **Breaking:** `DoubleDown.Repo.InMemory` renamed to
  `DoubleDown.Repo.OpenInMemory` (open-world, fallback-based).
  `DoubleDown.Repo.ClosedInMemory` renamed to
  `DoubleDown.Repo.InMemory` (closed-world, recommended default).
  The unqualified `InMemory` name now refers to the closed-world
  store — the one most users should reach for, especially with
  ExMachina factories.

- **Breaking:** `DoubleDown.Repo.Autogenerate` renamed to
  `DoubleDown.Repo.Impl.Autogenerate`.
  `DoubleDown.Repo.MultiStepper` renamed to
  `DoubleDown.Repo.Impl.MultiStepper`.
  `DoubleDown.Repo.InMemory.Shared` renamed to
  `DoubleDown.Repo.Impl.InMemoryShared`.
  Internal helpers moved to `Repo.Impl.*` namespace.

- `DoubleDown.BehaviourFacade.CompileHelper` renamed to
  `DoubleDown.Facade.CompileHelper`. The `Facade.*` namespace is
  shared internal infrastructure for all facade builders.

- Updated all documentation (README, getting-started, testing,
  dynamic, repo, migration, process-sharing, logging) for the
  new module names.

## [0.42.0]

### Added

- `DoubleDown.Repo.ClosedInMemory` — closed-world stateful Repo fake.
  Unlike `Repo.InMemory` (open-world, where absence means "I don't
  know"), `ClosedInMemory` treats the state as the complete truth —
  if a record isn't in the state, it doesn't exist. This makes the
  adapter authoritative for bare schema queryables without needing a
  fallback function:

  - **PK reads:** `get`/`get!` return `nil`/raise on miss (no fallback)
  - **Clause reads:** `get_by`/`get_by!` scan and filter all records
  - **Collection reads:** `all`, `one`/`one!`, `exists?` scan state
  - **Aggregates:** `count`/`sum`/`avg`/`min`/`max` computed from state
  - **Bulk writes:** `insert_all`, `delete_all`, `update_all`
    (with `set:` updates)

  `Ecto.Query` queryables still fall through to the fallback function
  (or raise), since evaluating query expressions requires a query
  engine. The fallback is the escape hatch, not the default path.

  Enables the pattern of using ExMachina factories to write test data
  into an in-memory store and testing against it without a database:

      DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.ClosedInMemory)
      insert(:user, name: "Alice", email: "alice@example.com")

      assert [%User{}] = MyApp.Repo.all(User)
      assert %User{} = MyApp.Repo.get_by(User, email: "alice@example.com")

- `DoubleDown.Repo.InMemory.Shared` — extracted shared helpers (state
  access, writes, transactions, fallback dispatch, query helpers) from
  `Repo.InMemory` into a shared module for reuse by `ClosedInMemory`.
  Pure refactor of `Repo.InMemory` — no behaviour change.

- Updated documentation across `docs/repo.md` (ClosedInMemory section
  with comparison table and ExMachina example), README (features table),
  and `mix.exs` (module groups).

## [0.41.1]

### Fixed

- `BehaviourFacade` compilation failure on clean builds when the
  behaviour and facade are in the same `elixirc_paths` batch.
  `Code.Typespec.fetch_callbacks/1` needs the behaviour's `.beam`
  file on disk, but during `mix compile` all files in the same
  batch are compiled together — `.beam` files aren't written until
  the batch finishes.

### Added

- `DoubleDown.BehaviourFacade.CompileHelper.ensure_compiled!/1` —
  explicitly compiles a behaviour source file and writes its `.beam`
  to the build directory. Only needed when the behaviour and facade
  are in the same compilation batch (e.g. both in `test/support/`).
  In normal usage the behaviour would be in `lib/` or a dependency,
  already compiled in a prior batch.

- `BehaviourIntrospection` now falls back to `:code.get_object_code/1`
  when `Code.Typespec.fetch_callbacks/1` can't find the `.beam` on the
  standard code path.

## [0.41.0]

### Added

- `DoubleDown.BehaviourFacade` — generates dispatch facades for vanilla
  Elixir `@behaviour` modules. Reads `@callback` declarations from
  compiled behaviour modules via `Code.Typespec.fetch_callbacks/1` and
  generates the same dispatch facade, `@spec` declarations, and
  `__key__` helpers as `DoubleDown.Facade`. Supports all dispatch
  paths (`test_dispatch?`, `static_dispatch?`, config-based).

      defmodule MyApp.Todos do
        use DoubleDown.BehaviourFacade,
          behaviour: MyApp.Todos.Behaviour,
          otp_app: :my_app
      end

  Use this for behaviours you don't control — third-party libraries,
  existing `@behaviour` modules, or any module with `@callback`
  declarations that you don't want to convert to `defcallback`.
  For behaviours you do control, `DoubleDown.Facade` with
  `defcallback` remains recommended (richer features: pre_dispatch
  transforms, `@doc` tag sync, combined contract + facade,
  compile-time spec mismatch warnings).

- `DoubleDown.Facade.Codegen` — extracted shared code generation
  (`generate_facade`, `generate_key_helper`, dispatch option
  resolution, static impl resolution, moduledoc generation) from
  `DoubleDown.Facade` into a shared module. Used by both `Facade`
  and `BehaviourFacade`. Pure refactor — no behaviour change.

- `DoubleDown.Facade.BehaviourIntrospection` — reads `@callback`
  declarations from compiled vanilla behaviour modules and converts
  them to the operation map format used by `Facade.Codegen`. Handles
  annotated params (`id :: String.t()`), bare types (`map()`), type
  variables from `when` clauses, zero-arg callbacks, and mixed
  param styles.

- `when` clause support in generated `@spec` declarations. Specs
  with bounded type variables (e.g.
  `@callback transform(input) :: output when input: term(), output: term()`)
  now preserve the `when` constraints in the facade's `@spec`.

- `DoubleDown.BehaviourFacade` and `DoubleDown.Dynamic` added to
  `groups_for_modules` in ex_doc config.

- Updated documentation across README, getting-started.md,
  dynamic.md, and all facade module `@moduledoc`s with the
  three-facade taxonomy and comparison tables.

## [0.40.0]

### Added

- `DoubleDown.Double.dynamic/1` — convenience for setting up a
  dynamically-faked module with its original implementation as the
  fallback. Pipes naturally with expects and stubs:

      SomeClient
      |> Double.dynamic()
      |> Double.expect(:fetch, fn [_] -> {:error, :timeout} end)

  Raises if the module hasn't been set up with `Dynamic.setup/1`.

## [0.39.0]

### Added

- `DoubleDown.Dynamic` — Mimic-style dynamic dispatch facades.
  `Dynamic.setup(Module)` copies a module's bytecode to a backup
  and replaces it with a dispatch shim, enabling the full Double
  API (expects, stubs, fakes, stateful responders, passthrough,
  cross-contract state access) without defining a contract or
  facade. Call in `test_helper.exs` before `ExUnit.start()`.
  Tests that don't install a handler get the original module's
  behaviour automatically. Async-safe.
- Guardrails: `Dynamic.setup/1` refuses DoubleDown contracts,
  DoubleDown internals, NimbleOwnership, and Erlang/OTP modules.
- `Dynamic.setup?/1` — check if a module has been set up.
- `Dynamic.original_module/1` — get the backup module name.
- `docs/dynamic.md` — full documentation with setup, usage,
  comparison table, and migration path from dynamic to
  contract-based facades.

## [0.38.0]

### Added

- Static dispatch facades now generate direct function calls
  (`Module.function(args)`) with `@compile {:inline, ...}` instead
  of `apply(Module, :function, [args])`. This allows the BEAM to
  inline facade functions at call sites — zero dispatch overhead,
  zero extra stack frames. Falls back to `apply` for operations
  with `pre_dispatch:` transforms where args are computed at runtime.

### Changed

- **Breaking:** Removed auto-bang variant generation from
  `defcallback`. The `:bang` option is no longer supported. Previously
  `defcallback insert(...) :: {:ok, T} | {:error, E}` would
  auto-generate `insert!/1`. This added complexity (bang_mode,
  extract_success_type, has_ok_error_pattern?) for limited value —
  Ecto already provides its own bang functions, and the generic
  wrappers produced unhelpful error messages.
- `bang: false` is no longer needed on `get!`, `get_by!`, `one!`,
  `transact`, and `rollback` declarations — they are now regular
  `defcallback` operations with no special treatment.
- `bang_mode` removed from `__callbacks__/0` introspection maps.

### Fixed

- Module fakes (`Double.fake(contract, Module)`) now run via
  `%Defer{}` in the calling process instead of inside the
  NimbleOwnership GenServer. Fixes `DBConnection.OwnershipError`
  when using `Double.fake(Repo, Backend.Repo)` for integration
  tests with real Ecto implementations.

## [0.37.2]

### Fixed

- Module fakes (`Double.fake(contract, Module)`) now run in the
  calling process instead of the NimbleOwnership GenServer process.
  Previously `invoke_module_fallback` called `apply(module, op, args)`
  directly inside `get_and_update`, which meant real implementations
  doing I/O (e.g. Ecto queries) ran in the GenServer — a process
  with no Ecto sandbox checkout. Now uses `%Defer{}` to move the
  `apply` outside the lock, matching how `transact` already works.
  This fixes `DBConnection.OwnershipError` when using
  `Double.fake(Repo, Backend.Repo)` in integration tests.

## [0.37.1]

### Added

- `DoubleDown.Double.allow/2,3` — convenience delegate to
  `DoubleDown.Testing.allow/2,3` for discoverability when using the
  Double API exclusively.
- Documented `:warn_on_typespec_mismatch?` option in `defcallback`
  `@doc`.

### Fixed

- Moved `DoubleDown.Defer` to `DoubleDown.Dispatch.Defer` — it's an
  internal dispatch mechanism, not user-facing.
- `invoke_stateful_fallback` now validates return tuple shape
  consistently with `invoke_expect` and `invoke_stub`. A stateful
  fake returning a bare value instead of `{result, new_state}` now
  raises a descriptive `ArgumentError` instead of a raw `MatchError`.
- `stub_handler?/1` and `fake_handler?/1` now check `@behaviour`
  declarations instead of duck-typing function exports. Previously
  any module with `new/2` would match `stub_handler?`.
- `Testing.allow/2` now has an explicit `@spec` (was missing for the
  2-arity form generated by the default argument).
- `verify!` error message no longer incorrectly says `verify!/0`
  when called via `verify!/1`.

## [0.37.0]

### Added

- `DoubleDown.Dispatch.StubHandler` behaviour for stateless stub
  handler modules. Implement `new/2` to make a stub usable by module
  name in `Double.stub`:

      Double.stub(Repo, Repo.Test)
      Double.stub(Repo, Repo.Test, fn :all, [User] -> [] end)

- `Repo.Test` implements `StubHandler`. `new/2` accepts a fallback
  function as the first arg and opts as the second. The legacy
  `new(fallback_fn: fn ...)` keyword form is still supported.
- `Double.stub/2` auto-detects StubHandler modules. `Double.stub/3`
  disambiguates StubHandler modules from per-operation stubs by
  checking if the second arg is a loaded module implementing the
  behaviour.

## [0.36.0]

### Added

- `DoubleDown.Dispatch.FakeHandler` behaviour for stateful fake
  handler modules. Implement `new/2` and `dispatch/3` (or `/4`) to
  make a fake usable by module name in `Double.fake`:

      Double.fake(Repo, Repo.InMemory)
      Double.fake(Repo, Repo.InMemory, [%User{id: 1}])
      Double.fake(Repo, Repo.InMemory, [%User{id: 1}], fallback_fn: fn ...)

- `Repo.InMemory` implements `FakeHandler`. `new/2` accepts seed
  data as the first arg (list of structs or pre-built store map)
  and opts as the second. The legacy `new(seed: [...], fallback_fn: ...)`
  keyword form is still supported.
- `Double.fake/2` auto-detects FakeHandler modules — if the module
  implements the behaviour, it's used as a stateful fake with default
  state. Non-FakeHandler modules are still treated as module fakes.

## [0.35.0]

### Added

- Stateful per-operation stubs. `DoubleDown.Double.stub/3` now accepts
  2-arity and 3-arity responder functions that can read and update the
  fake's state, with the same semantics as stateful expect responders.
  All arities can return `Double.passthrough()` to conditionally
  delegate to the fallback/fake. This enables the pattern "intercept
  every call, decide per-call whether to handle or delegate, without
  knowing the call count."

## [0.34.0]

### Added

- `DoubleDown.Double.passthrough/0` — returns a sentinel value that
  expect responders can return to conditionally delegate to the
  fallback/fake. The expect is still consumed for `verify!` counting.
  This enables patterns like "fail if duplicate, otherwise let the
  fake handle it" without duplicating the fake's logic. Works with
  all responder arities (1, 2, 3).

## [0.33.0]

### Added

- Stateful expect responders. `DoubleDown.Double.expect` now accepts
  2-arity and 3-arity responder functions that can read and update the
  stateful fake's state:
  - **2-arity:** `fn [args], state -> {result, new_state} end`
  - **3-arity:** `fn [args], state, all_states -> {result, new_state} end`
  (cross-contract state access)
  
  Stateful responders require `Double.fake/3` to be called first.
  `ArgumentError` is raised at `expect` time if no stateful fake is
  configured, and at dispatch time if the responder doesn't return a
  `{result, new_state}` tuple. 1-arity expects are unchanged.

### Fixed

- Removed stale "Limitation: no inline passthrough" notes from
  `DoubleDown.Double` moduledoc and `docs/testing.md` — this
  limitation no longer exists with stateful expect responders.
- Fixed historical `.Port.` module name references in docs.
- Removed stale `Skuld` reference in contract.ex comment.

## [0.32.0]

### Added

- 4-arity stateful handlers with read-only cross-contract state
  access. Handlers registered with
  `fn operation, args, state, all_states -> {result, new_state} end`
  receive a snapshot of all contract states as the 4th argument. This
  enables the "two-contract" pattern where a Queries handler reads
  the Repo InMemory store. Works with both `DoubleDown.Double.fake/3`
  and `DoubleDown.Testing.set_stateful_handler/3`. Existing 3-arity
  handlers are unchanged (non-breaking).
- `DoubleDown.Contract.GlobalState` sentinel key in the global state
  map. If a handler accidentally returns the global map instead of
  its own state, a clear `ArgumentError` is raised.

### Fixed

- Exceptions inside stateful handlers no longer crash the
  NimbleOwnership GenServer. Raises, throws, and exits that occur
  inside `NimbleOwnership.get_and_update` are now caught and
  transported to the calling process via `%Defer{}`, where they
  re-raise safely. Previously these would crash the ownership
  server — a singleton for the entire test run — aborting the suite.

## [0.31.1]

### Fixed

- Exceptions inside stateful handlers no longer crash the
  NimbleOwnership GenServer. Raises, throws, and exits that occur
  inside `NimbleOwnership.get_and_update` (e.g. a module fallback
  hitting a dead Ecto sandbox connection during test teardown) are
  now caught and transported to the calling process via `%Defer{}`,
  where they re-raise safely. Previously these would crash the
  ownership server — a singleton for the entire test run — aborting
  the suite.

## [0.31.0]

### Added

- Compile-time spec mismatch detection between `defcallback` type specs
  and the production implementation's `@spec` declarations. When a
  facade is compiled with a known static impl, param types and return
  types are compared and a `CompileError` is raised on mismatch. This
  catches the class of bug where a `defcallback` declares a narrower
  type than the impl accepts (e.g. `keyword()` vs `list()`), which
  would otherwise only surface as a non-local Dialyzer error.
- `warn_on_typespec_mismatch?: true` option on `defcallback` to
  downgrade the compile error to a warning for individual operations
  during migration.
- `DoubleDown.Contract.SpecWarnings` — private module handling spec
  fetching, type AST normalization, and comparison.

## [0.30.1]

### Fixed

- `transact` return type spec now includes the `Ecto.Multi` 4-tuple
  error shape: `{:error, term(), term(), term()}`. Previously the
  spec only declared `{:ok, term()} | {:error, term()}`, causing
  Dialyzer to conclude that code handling Multi's
  `{:error, failed_op, failed_value, changes_so_far}` return was
  unreachable.

## [0.30.0]

### Added

- Opts-accepting variants for all `DoubleDown.Repo` contract operations.
  Every operation now has both a base arity and an `+ opts` arity
  (e.g. `insert/1` and `insert/2`, `get/2` and `get/3`), matching
  `Ecto.Repo`'s actual API where every function accepts an optional
  `opts` keyword list. This fixes `UndefinedFunctionError` when
  `Ecto.Multi.update/4` (and `insert/4`, `delete/4`) receive a
  function argument — Multi's internal `:run` callbacks call
  `repo.update(changeset, opts)` with 2 args, which previously had
  no matching facade function.
- `Repo.Test` and `Repo.InMemory` handle opts-accepting dispatches
  by stripping opts and delegating to base-arity logic.

## [0.29.0]

### Added

- `get_by`/`get_by!` in `Repo.InMemory` now use 3-stage dispatch
  (state → fallback → error) when the queryable is a bare schema
  module and the clauses include all primary key fields. PK lookup
  uses the existing store index — no scan required. If found, any
  additional non-PK clauses are verified against the record. If not
  found in state, falls through to the fallback function (absence is
  not authoritative). Non-PK clauses, `Ecto.Query` queryables, and
  partial composite PKs still delegate to the fallback as before.
- Composite PK support in `get_by`/`get_by!` — all PK fields must
  be present in the clauses for a direct state lookup.

## [0.28.1]

### Changed

- `defcallback` macro `@doc` now includes full rationale for why
  `defcallback` is used instead of plain `@callback` (parameter names,
  combined contract+facade, LSP docs, additional metadata).
- `repo.md`: rollback section, operation dispatch table updated,
  `{:defer, fn}` references updated to `%DoubleDown.Defer{}`.
- `DoubleDown.Contract` `@moduledoc`: "typed port contracts" →
  "contract behaviours".

## [0.28.0]

### Added

- `rollback/1` added to `DoubleDown.Repo` contract (now 17 operations).
  Throws `{:rollback, value}` via `%Defer{}`, caught by `transact`
  which returns `{:error, value}`. Matches `Ecto.Repo.rollback/1` API.
  Both `Repo.Test` and `Repo.InMemory` support rollback — state
  mutations from earlier operations are not undone (documented
  limitation).
- Nested transact tests for both `Repo.Test` and `Repo.InMemory`,
  including via `Double.stub` and `Double.fake`.

## [0.27.0]

### Added

- `%DoubleDown.Defer{fn: fun}` struct — dedicated deferred execution
  marker, replacing the `{:defer, fn}` tuple convention. Eliminates
  clash risk with legitimate return values and enables deferred
  execution in all dispatch paths (fn, module, stateful).
- `Repo.Test` now returns `%Defer{}` for `transact` operations, so
  `Double.stub(contract, Repo.Test.new())` works correctly with
  transact — no NimbleOwnership deadlock.
- Regression tests for transact-via-`Double.stub` scenario.

### Changed

- **Breaking:** `{:defer, fn}` tuple convention replaced by
  `%DoubleDown.Defer{fn: fun}` throughout. Affects `Repo.Test`,
  `Repo.InMemory`, `DoubleDown.Dispatch`, and `DoubleDown.Double`.
  Only relevant if you were returning `{:defer, fn}` from custom
  stateful handlers — replace with `%DoubleDown.Defer{fn: fun}`.

### Fixed

- NimbleOwnership deadlock when using `Double.stub(contract,
  Repo.Test.new())` with contracts that include re-entrant operations
  like `transact`.
- Async test race condition: added `Code.ensure_loaded` before
  `function_exported?` in contract tests.
- Documentation: "contract behaviour" and "dispatch facade" compound
  forms at first-mention points, intro paragraphs on all doc pages,
  production Repo as zero-cost passthrough.

## [0.26.0]

### Changed

- **Breaking:** `DoubleDown.Handler` renamed to `DoubleDown.Double`.
  `stub` for module and stateful fallbacks split out into `fake`:
  - `Double.stub(contract, :op, fun)` — per-operation stub (canned value)
  - `Double.stub(contract, fun)` — 2-arity function fallback
  - `Double.fake(contract, module)` — module fake
  - `Double.fake(contract, fun, init_state)` — stateful fake
- **Breaking:** `DoubleDown.Log` API simplified — `match` and `reject`
  no longer take a contract parameter. The contract is specified once
  at `verify!` time. `verify!` now returns `{:ok, log}` on success.
- Handler error messages now include the contract name and args.
- `.formatter.exs` updated for `defcallback` rename.

### Added

- `DoubleDown.Log.verify!` returns `{:ok, log}` on success and
  includes the full dispatch log in all error messages — useful for
  REPL debugging.
- `:static_dispatch?` option on `use DoubleDown.Facade` — resolves
  the implementation module at compile time and generates direct
  function calls, eliminating `Application.get_env` overhead entirely.
  Defaults to `fn -> Mix.env() == :prod end`.
- Comprehensive docs review: restructured testing.md with `Double` as
  primary API, updated all examples to use `Double.expect`/`stub`/`fake`
  instead of raw `set_*_handler` APIs, consistent terminology throughout.

## [0.25.0]

### Changed

- **Breaking:** `defport` renamed to `defcallback`, `__port_operations__/0`
  renamed to `__callbacks__/0`. The `defcallback` macro uses the same
  syntax as `@callback` — replace the keyword and you're done.
- **Breaking:** `DoubleDown.Repo.Contract` renamed to `DoubleDown.Repo`.
  Less verbose in `Handler.stub` and `Handler.expect` calls.
- **Breaking:** `DoubleDown.Log` API simplified — `match` and `reject`
  no longer take a contract parameter. The contract is specified once
  at `verify!` time: `Log.match(:op, fn _ -> true end) |> Log.verify!(MyContract)`.

### Added

- `:static_dispatch?` option on `use DoubleDown.Facade` — resolves
  the implementation module at compile time and generates direct
  function calls, eliminating `Application.get_env` overhead entirely.
  Defaults to `fn -> Mix.env() == :prod end`. Falls back to runtime
  config dispatch when compile-time config is unavailable.
- README rewritten with new "Why DoubleDown?" section, Mox comparison,
  failure scenario example, and implementation snippet.
- Comprehensive docs review: "port" → "contract" throughout,
  terminology updated, fail-fast pattern documented, Skuld references
  simplified, LSP docs bullet added to `defcallback` rationale.

## [0.24.0]

### Changed

- **Breaking:** Library renamed from `hex_port` / `HexPort` to
  `double_down` / `DoubleDown`. All module names, app name, package
  name, and GitHub URLs updated. The emphasis has shifted from
  hexagonal architecture boundaries to the distinctive test double
  capabilities.

## [0.23.0]

### Changed

- **Breaking:** `DoubleDown.Double` API simplified — `expect` and `stub`
  now write directly to NimbleOwnership with immediate effect. Removed
  `%DoubleDown.Double{}` struct, `new/0`, and `install!/1`. All functions
  return the contract module atom for Mimic-style piping:

      MyContract
      |> DoubleDown.Double.stub(MyImpl)
      |> DoubleDown.Double.expect(:get, fn [id] -> %Thing{id: id} end)

  A canonical handler function is installed on first touch and reads
  dispatch config from state — no builder assembly step needed.

## [0.22.0]

### Added

- `DoubleDown.Double.expect/4..5` now accepts `:passthrough` as the
  handler argument. A `:passthrough` expect delegates to the
  configured fallback (fn, stateful, or module) while consuming the
  expect for `verify!` counting. Supports `times: n`. Enables
  call-counting without changing behaviour, and can be mixed with
  function expects for patterns like "first insert succeeds through
  InMemory, second fails".
- Documentation in `docs/repo.md` for using `DoubleDown.Double` with
  `Repo.Test` and `Repo.InMemory` for failure scenario testing,
  including error simulation, `:passthrough` call counting, and
  combined Handler + Log assertions.

### Fixed

- Added `@spec` clauses for all `stub/2..4` forms to satisfy
  Dialyzer.

## [0.21.0]

### Added

- `DoubleDown.Double.stub/3` (with accumulator: `stub/4`) for module
  fallback — delegates unhandled operations to a module implementing
  the contract's `@behaviour`. Validated at `install!` time.
- `DoubleDown.Double.stub/3` (with accumulator: `stub/4`) for stateful
  fallback — accepts a 3-arity `fn operation, args, state ->
  {result, new_state} end` with initial state, same signature as
  `set_stateful_handler`. Integrates stateful fakes (e.g.
  `Repo.InMemory`) into the Handler dispatch chain. Expects that
  short-circuit (e.g. error simulation) leave the fallback state
  unchanged.
- Fallback types are now a tagged union (`{:fn, fun}`,
  `{:stateful, fun, init_state}`, `{:module, module}`) — mutually
  exclusive, setting one replaces the other.

## [0.20.0]

### Added

- `DoubleDown.Double.verify_on_exit!/0` — registers an `on_exit`
  callback that automatically verifies all expectations after each
  test. Usable as `setup :verify_on_exit!`. Uses
  `NimbleOwnership.set_owner_to_manual_cleanup/2` to preserve
  ownership data until the on_exit callback runs.
- `DoubleDown.Double.verify!/1` — verifies expectations for a
  specific process pid, used internally by `verify_on_exit!/0`.

### Fixed

- Added `:ex_unit` to `plt_add_apps` in `mix.exs` so Dialyzer can
  resolve the `ExUnit.Callbacks.on_exit/2` call in
  `DoubleDown.Double.verify_on_exit!/0`.

## [0.19.0]

### Added

- `DoubleDown.Double.stub/2` and `stub/3` (with accumulator) for
  2-arity contract-wide fallback stubs. Accepts
  `fn operation, args -> result end` — the same signature as
  `set_fn_handler` — as a catch-all for operations without a
  specific expect or per-operation stub. Dispatch priority:
  expects > per-operation stubs > fallback stub > raise.

## [0.18.0]

### Added

- `DoubleDown.Double` — Mox-style expect/stub handler builder. Builds
  stateful handler functions from a declarative specification with
  multi-contract chaining and ordered expectations. API:
  `expect/3..5`, `stub/3..4`, `install!/1`, `verify!/0`.
- `DoubleDown.Log` — log-based expectation matcher. Declares structured
  expectations against the dispatch log after execution, matching on
  the full `{contract, operation, args, result}` tuple. Supports
  loose (default) and strict matching modes, `times: n` counting,
  and `reject` expectations. API: `match/3..5`, `reject/2..3`,
  `verify!/1..2`.
- Terminology mapping and glossary in README and getting-started
  guide, mapping DoubleDown concepts (contract, facade, test double,
  port) to familiar Elixir/Mox equivalents with a stub/mock/fake
  breakdown.

## [0.17.0]

### Changed

- **Breaking:** Renamed generated key helper from `key/N` to `__key__/N`
  on facade modules, following the Elixir convention for generated
  introspection functions. This avoids clashes with user-defined
  `defcallback key(...)` operations.

### Fixed

- Added `:mix` to `plt_add_apps` in `mix.exs` so Dialyzer can resolve
  the compile-time `Mix.env/0` call in `DoubleDown.Facade.__using__/1`.

## [0.16.1]

### Fixed

- Added `:mix` to `plt_add_apps` in `mix.exs` so Dialyzer can resolve
  the compile-time `Mix.env/0` call in `DoubleDown.Facade.__using__/1`.

### Changed

- Documentation updates for `:test_dispatch?` in `docs/getting-started.md`
  (dispatch resolution section) and `docs/testing.md` (setup section).

## [0.16.0]

### Added

- `:test_dispatch?` option for `use DoubleDown.Facade` — controls whether
  the generated facade includes the `NimbleOwnership`-based test handler
  resolution step. Accepts `true`, `false`, or a zero-arity function
  returning a boolean, evaluated at compile time. Defaults to
  `fn -> Mix.env() != :prod end`, so production builds get a config-only
  dispatch path with zero `NimbleOwnership` overhead (no
  `GenServer.whereis` ETS lookup).
- `DoubleDown.Dispatch.call_config/4` — config-only dispatch function that
  skips test handler resolution entirely. Used by facades compiled with
  `test_dispatch?: false`.

## [0.15.0]

### Added

- `pre_dispatch` option for `defcallback` — a generic mechanism for
  transforming arguments before dispatch. Accepts a function
  `(args, facade_module) -> args` declared at the contract level,
  spliced into the generated facade function as AST.
- `Repo.Test` tests split into dedicated `test/double_down/repo/test_test.exs`
  module.

### Changed

- 1-arity `transact` functions are now wrapped into 0-arity thunks
  at the facade boundary via `pre_dispatch`. The thunk closes over
  the facade module, so calls inside the function (e.g.
  `repo.insert(cs)`) go through the facade dispatch chain. This
  ensures facade-level concerns (logging, telemetry) apply in both
  test and production.
- `Repo.Test` and `Repo.InMemory` adapters no longer handle 1-arity
  transaction functions — they always receive 0-arity thunks (from
  `pre_dispatch` wrapping) or `Ecto.Multi` structs.
- The hardcoded `:transact` special-case in `DoubleDown.Facade` has been
  removed. The Repo-specific facade injection is now declared on the
  `defcallback` in `DoubleDown.Repo` using the generic
  `pre_dispatch` mechanism.

### Fixed

- User-supplied fallback functions in `Repo.InMemory` that raise
  non-`FunctionClauseError` exceptions (e.g. `RuntimeError`,
  `ArgumentError`) no longer crash the NimbleOwnership GenServer.
  Exceptions are captured and re-raised in the calling test process
  via `{:defer, fn -> reraise ... end}`.

## [0.14.0]

### Added

- `DoubleDown.Repo.insert_all/3` — standalone bulk insert
  operation, dispatched via fallback in both test adapters.
- `DoubleDown.Testing.set_mode_to_global/0` and `set_mode_to_private/0`
  — global handler mode for testing through supervision trees,
  Broadway pipelines, and other process trees where individual pids
  are not accessible. Uses NimbleOwnership shared mode. Incompatible
  with `async: true`.
- `DoubleDown.Repo.Autogenerate` — shared helper module for
  autogenerating primary keys and timestamps in test adapters.
  Handles `:id` (integer auto-increment), `:binary_id` (UUID),
  parameterized types (`Ecto.UUID`, `Uniq.UUID`, etc.), and
  `@primary_key false` schemas.
- `docs/migration.md` — incremental adoption guide covering the
  two-contract pattern, coexisting with direct Ecto.Repo calls, and
  the fail-fast test config pattern.
- Process-testing patterns in `docs/testing.md` — decision table,
  GenServer example, supervision tree example.

### Changed

- Test adapters (`Repo.Test`, `Repo.InMemory`) now check
  `changeset.valid?` before applying changes — invalid changesets
  return `{:error, changeset}`, matching real Ecto.Repo behaviour.
- Test adapters now populate `inserted_at`/`updated_at` timestamps
  via Ecto's `__schema__(:autogenerate)` metadata. Custom field
  names and timestamp types are handled automatically.
- 1-arity `transact` functions now receive the facade module instead
  of `nil`, enabling `fn repo -> repo.insert(cs) end` patterns.
- The internal opts key for threading the facade module through
  transact was renamed from `:repo_facade` to `DoubleDown.Repo.Facade`
  for proper namespacing.
- Primary key autogeneration is now metadata-driven — supports
  `:binary_id` (UUID), `Ecto.UUID`, and other parameterized types.
  Raises `ArgumentError` when autogeneration is not configured and
  no PK value is provided.
- Autogeneration logic extracted from `Repo.Test` and
  `Repo.InMemory` into shared `DoubleDown.Repo.Autogenerate` module.
- Repo contract now has 16 operations (was 15).

### Fixed

- Invalid changesets passed to `Repo.Test` or `Repo.InMemory`
  `insert`/`update` no longer silently succeed — they return
  `{:error, changeset}`.
- `Repo.InMemory` store is unchanged after a failed insert/update
  with an invalid changeset.

## [0.13.0]

### Added

- Fail-fast documentation for `impl: nil` test configuration.

### Changed

- Improved error messages when no implementation is configured in
  test mode.

## [0.12.0]

### Changed

- Removed unused Ecto wrapper macro.
- Version now read from `VERSION` file.

## [0.11.1]

### Changed

- Documentation improvements (README, hexdocs, testing guide).
- Removed unnecessary `reset` calls from test examples.

## [0.11.0]

### Fixed

- Fixed compiler warnings.

## [0.10.0]

### Added

- `Facade` without implicit `Contract` — `use DoubleDown.Facade` with
  an explicit `:contract` option for separate contract modules.
- Documentation explaining why `defcallback` is used instead of standard
  `@callback` declarations.

## [0.9.0]

### Added

- Single-module `Contract + Facade` — `use DoubleDown.Facade` without
  a `:contract` option implicitly sets up the contract in the same
  module.

### Changed

- Dispatch references the contract module, not the facade.

## [0.8.0]

### Added

- `DoubleDown.Repo` — built-in 15-operation Ecto Repo
  contract with `Repo.Test` (stateless) and `Repo.InMemory`
  (stateful) test doubles.
- `MultiStepper` for stepping through `Ecto.Multi` operations
  without a database.

### Changed

- Renamed `Port` to `Facade` throughout.
- Removed separate `.Behaviour` module — behaviours are generated
  directly on the contract module.

## [0.7.0]

### Changed

- `Repo.InMemory` fallback function now receives state as a third
  argument `(operation, args, state)`, enabling fallbacks that
  compose canned data with records inserted during the test.

## [0.6.0]

### Fixed

- Made `DoubleDown.Contract.__using__/1` idempotent — safe to `use`
  multiple times.

## [0.5.0]

### Changed

- Improved `Repo.Test` stateless handler.

## [0.4.0]

### Added

- `Repo.InMemory` — stateful in-memory Repo implementation with
  read-after-write consistency for PK-based lookups.
- NimbleOwnership-based process-scoped handler isolation for
  `async: true` tests.

## [0.3.1]

### Fixed

- Expand type aliases at macro time in `defcallback` to resolve
  Dialyzer `unknown_type` errors.

## [0.3.0]

### Added

- `transact` defcallback with `{:defer, fn}` support for stateful
  dispatch — avoids NimbleOwnership deadlocks.
- `Repo.transact!` for `Ecto.Multi` operations.

## [0.2.0]

### Changed

- Split `DoubleDown` into `DoubleDown.Contract` and `DoubleDown.Port`
  (later renamed to `Facade`).

## [0.1.0]

### Added

- Initial release — `defcallback` macro, `DoubleDown.Contract`,
  `DoubleDown.Testing` with NimbleOwnership, `Repo.Test` stateless
  adapter, CI setup, Credo, Dialyzer.

[0.49.0]: https://github.com/mccraigmccraig/double_down/compare/v0.48.1...v0.49.0
[0.48.1]: https://github.com/mccraigmccraig/double_down/compare/v0.48.0...v0.48.1
[0.48.0]: https://github.com/mccraigmccraig/double_down/compare/v0.47.2...v0.48.0
[0.47.2]: https://github.com/mccraigmccraig/double_down/compare/v0.47.1...v0.47.2
[0.47.1]: https://github.com/mccraigmccraig/double_down/compare/v0.47.0...v0.47.1
[0.47.0]: https://github.com/mccraigmccraig/double_down/compare/v0.46.3...v0.47.0
[0.46.3]: https://github.com/mccraigmccraig/double_down/compare/v0.46.2...v0.46.3
[0.46.2]: https://github.com/mccraigmccraig/double_down/compare/v0.46.1...v0.46.2
[0.46.1]: https://github.com/mccraigmccraig/double_down/compare/v0.46.0...v0.46.1
[0.46.0]: https://github.com/mccraigmccraig/double_down/compare/v0.45.0...v0.46.0
[0.45.0]: https://github.com/mccraigmccraig/double_down/compare/v0.44.0...v0.45.0
[0.44.0]: https://github.com/mccraigmccraig/double_down/compare/v0.43.0...v0.44.0
[0.43.0]: https://github.com/mccraigmccraig/double_down/compare/v0.42.0...v0.43.0
[0.42.0]: https://github.com/mccraigmccraig/double_down/compare/v0.41.1...v0.42.0
[0.41.1]: https://github.com/mccraigmccraig/double_down/compare/v0.41.0...v0.41.1
[0.41.0]: https://github.com/mccraigmccraig/double_down/compare/v0.40.0...v0.41.0
[0.40.0]: https://github.com/mccraigmccraig/double_down/compare/v0.39.0...v0.40.0
[0.39.0]: https://github.com/mccraigmccraig/double_down/compare/v0.38.0...v0.39.0
[0.38.0]: https://github.com/mccraigmccraig/double_down/compare/v0.37.2...v0.38.0
[0.37.2]: https://github.com/mccraigmccraig/double_down/compare/v0.37.1...v0.37.2
[0.37.1]: https://github.com/mccraigmccraig/double_down/compare/v0.37.0...v0.37.1
[0.37.0]: https://github.com/mccraigmccraig/double_down/compare/v0.36.0...v0.37.0
[0.36.0]: https://github.com/mccraigmccraig/double_down/compare/v0.35.0...v0.36.0
[0.35.0]: https://github.com/mccraigmccraig/double_down/compare/v0.34.0...v0.35.0
[0.34.0]: https://github.com/mccraigmccraig/double_down/compare/v0.33.0...v0.34.0
[0.33.0]: https://github.com/mccraigmccraig/double_down/compare/v0.32.0...v0.33.0
[0.32.0]: https://github.com/mccraigmccraig/double_down/compare/v0.31.1...v0.32.0
[0.31.1]: https://github.com/mccraigmccraig/double_down/compare/v0.31.0...v0.31.1
[0.31.0]: https://github.com/mccraigmccraig/double_down/compare/v0.30.1...v0.31.0
[0.30.1]: https://github.com/mccraigmccraig/double_down/compare/v0.30.0...v0.30.1
[0.30.0]: https://github.com/mccraigmccraig/double_down/compare/v0.29.0...v0.30.0
[0.29.0]: https://github.com/mccraigmccraig/double_down/compare/v0.28.1...v0.29.0
[0.28.1]: https://github.com/mccraigmccraig/double_down/compare/v0.28.0...v0.28.1
[0.28.0]: https://github.com/mccraigmccraig/double_down/compare/v0.27.0...v0.28.0
[0.27.0]: https://github.com/mccraigmccraig/double_down/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/mccraigmccraig/double_down/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/mccraigmccraig/double_down/compare/v0.24.0...v0.25.0
[0.24.0]: https://github.com/mccraigmccraig/double_down/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/mccraigmccraig/double_down/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/mccraigmccraig/double_down/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/mccraigmccraig/double_down/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/mccraigmccraig/double_down/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/mccraigmccraig/double_down/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/mccraigmccraig/double_down/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/mccraigmccraig/double_down/compare/v0.16.1...v0.17.0
[0.16.1]: https://github.com/mccraigmccraig/double_down/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/mccraigmccraig/double_down/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/mccraigmccraig/double_down/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/mccraigmccraig/double_down/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/mccraigmccraig/double_down/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/mccraigmccraig/double_down/compare/v0.11.1...v0.12.0
[0.11.1]: https://github.com/mccraigmccraig/double_down/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/mccraigmccraig/double_down/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/mccraigmccraig/double_down/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/mccraigmccraig/double_down/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/mccraigmccraig/double_down/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/mccraigmccraig/double_down/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/mccraigmccraig/double_down/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/mccraigmccraig/double_down/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mccraigmccraig/double_down/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/mccraigmccraig/double_down/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mccraigmccraig/double_down/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mccraigmccraig/double_down/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mccraigmccraig/double_down/releases/tag/v0.1.0
