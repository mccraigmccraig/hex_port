defmodule DoubleDown.Contract.Dispatch.Keys do
  @moduledoc """
  Centralised NimbleOwnership key helpers for DoubleDown dispatch.

  All test-time state is stored in a single `NimbleOwnership` GenServer
  keyed by atoms derived from the contract module. This module provides
  the canonical key-generation functions so that `Dispatch`, `Double`,
  and `Testing` all agree on the key scheme.

  ## Key scheme

  | Key | Function | Purpose |
  |-----|----------|---------|
  | `ownership_server/0` | Server name | The `NimbleOwnership` GenServer registered name |
  | contract module atom | (no function) | Handler meta + inline state for stateful handlers |
  | `log_key/1` | Per-contract | Accumulated `{contract, op, args, result}` call log |
  | `contracts_key/0` | Global | Set of contracts with active `Double` expects |
  """

  @doc """
  The registered name of the NimbleOwnership GenServer.
  """
  @spec ownership_server() :: atom()
  def ownership_server, do: DoubleDown.Contract.Dispatch.Ownership

  @doc """
  NimbleOwnership key for a contract's dispatch call log.
  """
  @spec log_key(module()) :: atom()
  def log_key(contract), do: Module.concat(DoubleDown.Log, contract)

  @doc """
  NimbleOwnership key for the set of contracts with active `Double` expects/stubs.
  """
  @spec contracts_key() :: atom()
  def contracts_key, do: DoubleDown.Double.Contracts
end
