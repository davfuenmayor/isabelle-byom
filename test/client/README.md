# Remote client verification

Run these checks from a sibling `isabelle_elixir` checkout that supports
[Isabelle BYOM](https://github.com/davfuenmayor/isabelle-byom). Set the deployed
server's URL and native password for the integration checks. The transport
and local file-placement checks can run without those credentials.

```bash
mix run ../isabelle-byom/test/client/transport.exs
mix run ../isabelle-byom/test/client/files.exs
```

```bash
export ISABELLE_URL=wss://YOUR-HOST/isabelle
read -r -s -p 'Native server password: ' ISABELLE_PASSWORD; echo
export ISABELLE_PASSWORD
mix run ../isabelle-byom/test/client/remote.exs
mix run ../isabelle-byom/test/client/cleanup.exs
mix run ../isabelle-byom/test/client/livebooks.exs
mix run ../isabelle-byom/test/client/livebooks.exs ../isabelle-byom/livebooks/remote/Client.livemd ../isabelle-byom/livebooks/remote/ClientShared.livemd
```

The notebook runner preserves section/branch bindings. It tracks successful
resource-creating calls even when a later expression in the same cell fails.
Its `after` block stops known sessions, releases projects, then closes connections;
local servers it started are also stopped. It never shuts down a remote server.
Cleanup tests deliberately fail cells and verify their handles are no longer
usable. An unreachable server cannot guarantee immediate cleanup.
