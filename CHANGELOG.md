# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.21.0]

### Added

- `HexPort.Handler.stub/3` (with accumulator: `stub/4`) for module
  fallback — delegates unhandled operations to a module implementing
  the contract's `@behaviour`. Validated at `install!` time.
- `HexPort.Handler.stub/3` (with accumulator: `stub/4`) for stateful
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

- `HexPort.Handler.verify_on_exit!/0` — registers an `on_exit`
  callback that automatically verifies all expectations after each
  test. Usable as `setup :verify_on_exit!`. Uses
  `NimbleOwnership.set_owner_to_manual_cleanup/2` to preserve
  ownership data until the on_exit callback runs.
- `HexPort.Handler.verify!/1` — verifies expectations for a
  specific process pid, used internally by `verify_on_exit!/0`.

### Fixed

- Added `:ex_unit` to `plt_add_apps` in `mix.exs` so Dialyzer can
  resolve the `ExUnit.Callbacks.on_exit/2` call in
  `HexPort.Handler.verify_on_exit!/0`.

## [0.19.0]

### Added

- `HexPort.Handler.stub/2` and `stub/3` (with accumulator) for
  2-arity contract-wide fallback stubs. Accepts
  `fn operation, args -> result end` — the same signature as
  `set_fn_handler` — as a catch-all for operations without a
  specific expect or per-operation stub. Dispatch priority:
  expects > per-operation stubs > fallback stub > raise.

## [0.18.0]

### Added

- `HexPort.Handler` — Mox-style expect/stub handler builder. Builds
  stateful handler functions from a declarative specification with
  multi-contract chaining and ordered expectations. API:
  `expect/3..5`, `stub/3..4`, `install!/1`, `verify!/0`.
- `HexPort.Log` — log-based expectation matcher. Declares structured
  expectations against the dispatch log after execution, matching on
  the full `{contract, operation, args, result}` tuple. Supports
  loose (default) and strict matching modes, `times: n` counting,
  and `reject` expectations. API: `match/3..5`, `reject/2..3`,
  `verify!/1..2`.
- Terminology mapping and glossary in README and getting-started
  guide, mapping HexPort concepts (contract, facade, test double,
  port) to familiar Elixir/Mox equivalents with a stub/mock/fake
  breakdown.

## [0.17.0]

### Changed

- **Breaking:** Renamed generated key helper from `key/N` to `__key__/N`
  on facade modules, following the Elixir convention for generated
  introspection functions. This avoids clashes with user-defined
  `defport key(...)` operations.

### Fixed

- Added `:mix` to `plt_add_apps` in `mix.exs` so Dialyzer can resolve
  the compile-time `Mix.env/0` call in `HexPort.Facade.__using__/1`.

## [0.16.1]

### Fixed

- Added `:mix` to `plt_add_apps` in `mix.exs` so Dialyzer can resolve
  the compile-time `Mix.env/0` call in `HexPort.Facade.__using__/1`.

### Changed

- Documentation updates for `:test_dispatch?` in `docs/getting-started.md`
  (dispatch resolution section) and `docs/testing.md` (setup section).

## [0.16.0]

### Added

- `:test_dispatch?` option for `use HexPort.Facade` — controls whether
  the generated facade includes the `NimbleOwnership`-based test handler
  resolution step. Accepts `true`, `false`, or a zero-arity function
  returning a boolean, evaluated at compile time. Defaults to
  `fn -> Mix.env() != :prod end`, so production builds get a config-only
  dispatch path with zero `NimbleOwnership` overhead (no
  `GenServer.whereis` ETS lookup).
- `HexPort.Dispatch.call_config/4` — config-only dispatch function that
  skips test handler resolution entirely. Used by facades compiled with
  `test_dispatch?: false`.

## [0.15.0]

### Added

- `pre_dispatch` option for `defport` — a generic mechanism for
  transforming arguments before dispatch. Accepts a function
  `(args, facade_module) -> args` declared at the contract level,
  spliced into the generated facade function as AST.
- `Repo.Test` tests split into dedicated `test/hex_port/repo/test_test.exs`
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
- The hardcoded `:transact` special-case in `HexPort.Facade` has been
  removed. The Repo-specific facade injection is now declared on the
  `defport` in `HexPort.Repo.Contract` using the generic
  `pre_dispatch` mechanism.

### Fixed

- User-supplied fallback functions in `Repo.InMemory` that raise
  non-`FunctionClauseError` exceptions (e.g. `RuntimeError`,
  `ArgumentError`) no longer crash the NimbleOwnership GenServer.
  Exceptions are captured and re-raised in the calling test process
  via `{:defer, fn -> reraise ... end}`.

## [0.14.0]

### Added

- `HexPort.Repo.Contract.insert_all/3` — standalone bulk insert
  operation, dispatched via fallback in both test adapters.
- `HexPort.Testing.set_mode_to_global/0` and `set_mode_to_private/0`
  — global handler mode for testing through supervision trees,
  Broadway pipelines, and other process trees where individual pids
  are not accessible. Uses NimbleOwnership shared mode. Incompatible
  with `async: true`.
- `HexPort.Repo.Autogenerate` — shared helper module for
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
  transact was renamed from `:repo_facade` to `HexPort.Repo.Facade`
  for proper namespacing.
- Primary key autogeneration is now metadata-driven — supports
  `:binary_id` (UUID), `Ecto.UUID`, and other parameterized types.
  Raises `ArgumentError` when autogeneration is not configured and
  no PK value is provided.
- Autogeneration logic extracted from `Repo.Test` and
  `Repo.InMemory` into shared `HexPort.Repo.Autogenerate` module.
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

- `Facade` without implicit `Contract` — `use HexPort.Facade` with
  an explicit `:contract` option for separate contract modules.
- Documentation explaining why `defport` is used instead of standard
  `@callback` declarations.

## [0.9.0]

### Added

- Single-module `Contract + Facade` — `use HexPort.Facade` without
  a `:contract` option implicitly sets up the contract in the same
  module.

### Changed

- Dispatch references the contract module, not the facade.

## [0.8.0]

### Added

- `HexPort.Repo.Contract` — built-in 15-operation Ecto Repo
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

- Made `HexPort.Contract.__using__/1` idempotent — safe to `use`
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

- Expand type aliases at macro time in `defport` to resolve
  Dialyzer `unknown_type` errors.

## [0.3.0]

### Added

- `transact` defport with `{:defer, fn}` support for stateful
  dispatch — avoids NimbleOwnership deadlocks.
- `Repo.transact!` for `Ecto.Multi` operations.

## [0.2.0]

### Changed

- Split `HexPort` into `HexPort.Contract` and `HexPort.Port`
  (later renamed to `Facade`).

## [0.1.0]

### Added

- Initial release — `defport` macro, `HexPort.Contract`,
  `HexPort.Testing` with NimbleOwnership, `Repo.Test` stateless
  adapter, CI setup, Credo, Dialyzer.

[Unreleased]: https://github.com/mccraigmccraig/hex_port/compare/v0.21.0...HEAD
[0.21.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.16.1...v0.17.0
[0.16.1]: https://github.com/mccraigmccraig/hex_port/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.11.1...v0.12.0
[0.11.1]: https://github.com/mccraigmccraig/hex_port/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/mccraigmccraig/hex_port/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mccraigmccraig/hex_port/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mccraigmccraig/hex_port/releases/tag/v0.1.0
