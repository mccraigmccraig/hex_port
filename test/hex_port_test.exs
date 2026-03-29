defmodule HexPortTest do
  use ExUnit.Case, async: true

  test "HexPort module exists" do
    assert Code.ensure_loaded?(HexPort)
  end

  test "HexPort.Contract module exists" do
    assert Code.ensure_loaded?(HexPort.Contract)
  end

  test "HexPort.Dispatch module exists" do
    assert Code.ensure_loaded?(HexPort.Dispatch)
  end

  test "HexPort.Testing module exists" do
    assert Code.ensure_loaded?(HexPort.Testing)
  end
end
