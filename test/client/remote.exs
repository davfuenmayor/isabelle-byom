ExUnit.start()

defmodule BYOMRemoteTest do
  use ExUnit.Case
  alias IsabelleClient, as: Client

  setup do
    password = System.fetch_env!("ISABELLE_PASSWORD")
    url = System.fetch_env!("ISABELLE_URL")
    {:ok, client} = Client.connect(password, url: url)
    on_exit(fn -> Client.close(client) end)
    %{client: client, password: password, url: url}
  end

  test "large Unicode echo, authentication rejection and project ownership", %{
    client: c,
    url: url
  } do
    text = String.duplicate("λ🙂\n", 100_000)
    assert {:ok, ^text} = Client.echo(c, text)
    assert {:error, _} = Client.connect("incorrect", url: url)
    assert {:ok, project} = Client.create_project(c)

    try do
      assert {:error, _} = Client.write_project_file(c, project, "../escape", "no")

      assert {:ok, %{"path" => path}} =
               Client.write_project_file(c, project, "sub/Example.thy", "text")

      assert String.starts_with?(path, project["dir"] <> "/")
    after
      assert {:ok, _} = Client.remove_project(c, project)
    end

    assert {:error, _} = Client.write_project_file(c, project, "gone", "text")
  end

  test "session file errors, TPTP and theory checking", %{client: c} do
    {:ok, c, _} = Client.start_session(c, [session: "HOL"], 120_000)

    try do
      assert {:error, _} = Client.write_file(c, "../escape", "no")

      assert {:ok, task} =
               Client.check_text(c, "RemoteUnicode", ~s(lemma "x = x" by simp), [], 120_000)

      assert task.result["ok"]
      assert {:ok, task} = IsabelleClient.TPTP.load(c, 120_000)
      assert task.result["ok"]
    after
      {:ok, _, _} = Client.stop_session(c)
    end
  end
end
