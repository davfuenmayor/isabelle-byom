# Remote client verification

Run these integration checks from a sibling `isabelle_elixir` checkout.
Use a BYOM deployment that matches the client protocol. The client's own
`mix test` suite covers loopback transport and local file placement.

```bash
export ISABELLE_URL=wss://YOUR-HOST/isabelle
read -r -s -p 'Native server password: ' ISABELLE_PASSWORD; echo
export ISABELLE_PASSWORD
mix run ../isabelle-byom/test/client/remote.exs
mix run ../isabelle-byom/test/client/cleanup.exs
mix run ../isabelle-byom/test/client/livebooks.exs
```

The notebook runner preserves section/branch bindings. It tracks successful
resource-creating calls even when a later expression in the same cell fails.
Its `after` block stops known sessions, releases projects, then closes connections;
local servers it started are also stopped. It never shuts down a remote server.
Cleanup tests deliberately fail cells and verify their handles are no longer
usable. An unreachable server cannot guarantee immediate cleanup.
