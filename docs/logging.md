# Logging

[< Dynamic Facades](dynamic.md) | [Up: README](../README.md) | [Process Sharing >](process-sharing.md)

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

This is particularly valuable with fakes like `Repo.Stub` that do
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

---

[< Dynamic Facades](dynamic.md) | [Up: README](../README.md) | [Process Sharing >](process-sharing.md)
