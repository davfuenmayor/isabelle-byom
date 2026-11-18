Code.require_file("resources.exs", __DIR__)
# Run from isabelle_elixir: mix run ../isabelle-byom/test/client/livebooks.exs
# Evaluate the existing cells with their Livebook section/branch bindings.
System.put_env("LB_ISABELLE_URL", System.fetch_env!("ISABELLE_URL"))
System.put_env("LB_ISABELLE_PASSWORD", System.fetch_env!("ISABELLE_PASSWORD"))

defaults = [
  Path.expand("../../livebooks/Client.livemd", __DIR__),
  Path.expand("../../livebooks/remote/ClientShared.livemd", __DIR__)
]

for path <- if(System.argv() == [], do: defaults, else: System.argv()) do
  name = Path.basename(path)

  tokens =
    Regex.scan(
      ~r/<!-- livebook:\{"branch_parent_index":(\d+)\} -->|^## [^\n]+|```elixir\n(.*?)\n```/ms,
      File.read!(path)
    )

  initial = %{binding: [], sections: %{}, section: -1, parent: nil, cell: 0, clients: []}

  IntegrationResources.run(fn ->
    state =
      Enum.reduce(tokens, initial, fn [token | _], state ->
        cond do
          String.starts_with?(token, "<!--") ->
            [_, index] = Regex.run(~r/branch_parent_index":(\d+)/, token)
            %{state | parent: String.to_integer(index)}

          String.starts_with?(token, "## ") ->
            sections = Map.put(state.sections, state.section, state.binding)
            binding = if state.parent, do: Map.fetch!(sections, state.parent), else: state.binding

            %{
              state
              | sections: sections,
                binding: binding,
                section: state.section + 1,
                parent: nil
            }

          String.contains?(token, "Mix.install") ->
            state

          true ->
            [_, code] = Regex.run(~r/```elixir\n(.*?)\n```/s, token)
            IO.puts("#{name}: cell #{state.cell + 1}")

            {_value, binding} =
              code
              |> Code.string_to_quoted!()
              |> IntegrationResources.instrument()
              |> Code.eval_quoted(state.binding, file: path)

            clients =
              case Keyword.get(binding, :client) do
                %IsabelleClient{} = c -> [c | state.clients]
                _ -> state.clients
              end

            %{state | binding: binding, cell: state.cell + 1, clients: clients}
        end
      end)

    IO.puts("#{name}: #{state.cell} executable cells passed")
  end)
end
