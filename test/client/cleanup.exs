Code.require_file("resources.exs", __DIR__)
ExUnit.start()

defmodule IntegrationCleanupTest do
  use ExUnit.Case

  test "a failure mid-cell releases sessions, projects and the connection" do
    opts = [url: System.fetch_env!("ISABELLE_URL")]
    password = System.fetch_env!("ISABELLE_PASSWORD")

    assert_raise RuntimeError, "deliberate failed cell", fn ->
      IntegrationResources.run(fn ->
        code = """
        {:ok, client} = IsabelleClient.connect(password, opts)
        {:ok, client, task} = IsabelleClient.start_session(client, [session: "HOL"], 120_000)
        {:ok, project} = IsabelleClient.create_project(client)
        Process.put(:created, {client.socket, task.result["session_id"], project})
        raise "deliberate failed cell"
        """

        code
        |> Code.string_to_quoted!()
        |> IntegrationResources.instrument()
        |> Code.eval_quoted(password: password, opts: opts)
      end)
    end

    {socket, session, project} = Process.delete(:created)
    assert {:error, _} = IsabelleClient.Transport.send(socket, "help\n")
    {:ok, checker} = IsabelleClient.connect(password, opts)

    try do
      assert {:error, _} =
               IsabelleClient.write_file(checker, "gone", "no", session_id: session)

      assert {:error, _} = IsabelleClient.write_project_file(checker, project, "gone", "no")
    after
      IsabelleClient.close(checker)
    end
  end

  test "linked task failure still runs cleanup" do
    password = System.fetch_env!("ISABELLE_PASSWORD")
    opts = [url: System.fetch_env!("ISABELLE_URL")]

    assert catch_exit(
             IntegrationResources.run(fn ->
               {:ok, client} =
                 IntegrationResources.call(IsabelleClient, :connect, [password, opts])

               Process.put(:linked_socket, client.socket)
               task = Task.async(fn -> raise "linked task failed" end)
               Task.await(task)
             end)
           )

    assert {:error, _} = IsabelleClient.Transport.send(Process.delete(:linked_socket), "help\n")
  end

  test "a failed Shared cell closes its process and stops its sessions" do
    password = System.fetch_env!("ISABELLE_PASSWORD")
    url = System.fetch_env!("ISABELLE_URL")

    assert_raise RuntimeError, fn ->
      IntegrationResources.run(fn ->
        code = """
        {:ok, shared} = IsabelleClient.Shared.connect(password: password, url: url)
        {:ok, task} = IsabelleClient.Shared.start_session(shared, [session: "HOL"], 120_000)
        {:ok, _path} = IsabelleClient.Shared.write_file(shared, "shared.txt", "λ")
        Process.put(:shared_created, {shared, task.result["session_id"]})
        raise "deliberate failure"
        """

        code
        |> Code.string_to_quoted!()
        |> IntegrationResources.instrument()
        |> Code.eval_quoted(password: password, url: url)
      end)
    end

    {shared, session} = Process.delete(:shared_created)
    refute Process.alive?(shared)
    {:ok, checker} = IsabelleClient.connect(password, url: url)

    try do
      assert {:error, _} =
               IsabelleClient.write_file(checker, "gone", "no", session_id: session)
    after
      IsabelleClient.close(checker)
    end
  end
end
