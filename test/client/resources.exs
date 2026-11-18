defmodule IntegrationResources do
  @moduledoc false
  @key {__MODULE__, :resources}

  def run(fun) do
    Process.put(@key, [])
    trap_exit = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      cleanup()
      Process.delete(@key)
      Process.flag(:trap_exit, trap_exit)
    end
  end

  # Rewriting only notebook calls keeps this test bookkeeping out of the SDK.
  def instrument(ast) do
    ast =
      Macro.prewalk(ast, fn
        {:|>, _, [left, right]} -> Macro.pipe(left, right, 0)
        node -> node
      end)

    Macro.postwalk(ast, fn
      {{:., _, [{:__aliases__, _, parts}, name]}, _, args}
      when parts in [[:IsabelleClient], [:IsabelleClient, :Shared]] and
             name in [
               :start_server,
               :connect,
               :start_link,
               :start_session,
               :create_project,
               :close
             ] and
             is_list(args) ->
        module = Module.concat(parts)

        quote do:
                IntegrationResources.call(unquote(module), unquote(name), [unquote_splicing(args)])

      node ->
        node
    end)
  end

  def call(module, name, args) do
    if name == :close do
      cleanup()
      :ok
    else
      do_call(module, name, args)
    end
  end

  defp do_call(module, name, args) do
    result = apply(module, name, args)

    case {module, name, result} do
      {IsabelleClient, :start_server, {:ok, info}} ->
        remember({:server, info.name})

      {IsabelleClient, :connect, {:ok, client}} ->
        remember({:connection, module, client})

      {IsabelleClient.Shared, name, {:ok, pid}} when name in [:connect, :start_link] ->
        remember({:connection, module, pid})

      {IsabelleClient, :start_session, {:ok, client, task}} ->
        remember({:session, module, client, task.result["session_id"]})

      {IsabelleClient.Shared, :start_session, {:ok, task}} ->
        remember({:session, module, hd(args), task.result["session_id"]})

      {IsabelleClient, :create_project, {:ok, project}} ->
        remember({:project, module, hd(args), project})

      _ ->
        :ok
    end

    result
  end

  defp remember(resource), do: Process.put(@key, [resource | Process.get(@key, [])])

  defp cleanup do
    resources = Process.get(@key, [])
    # Stop every session before releasing any project, then close connections.
    for resource <- Enum.sort_by(Enum.uniq(resources), &priority/1) do
      try do
        case resource do
          {:session, module, handle, id} -> apply(module, :stop_session, [handle, id, 30_000])
          {:project, module, handle, project} -> apply(module, :remove_project, [handle, project])
          {:connection, module, handle} -> apply(module, :close, [handle])
          {:server, name} -> IsabelleClient.Raw.kill_server(name)
        end
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    Process.put(@key, [])
  end

  defp priority({:session, _, _, _}), do: 0
  defp priority({:project, _, _, _}), do: 1
  defp priority({:connection, _, _}), do: 2
  defp priority(_), do: 3
end
