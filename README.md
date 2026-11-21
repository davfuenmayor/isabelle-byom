# Isabelle BYOM (Bring Your Own Machine for Isabelle)

BYOM deploys an Isabelle server to infrastructure you control. Users
connect with a WebSocket URL and the native server password. The example
shows how to check theories remotely with `isabelle_elixir`. [Example Livebook](livebooks/Client.livemd)

## Run BYOM

### Local requirements

Run BYOM on Linux or macOS with Bash, standard Unix utilities, and the tools
for your provider.

| Provider | Tools on the deployer's computer |
| --- | --- |
| [Fly](providers/fly/README.md) | Fly CLI and `jq` |
| [Hetzner](providers/hetzner/README.md) | `hcloud` and OpenSSH |
| [Slurm](providers/hpc/README.md) | OpenSSH and `websocat` |

The runner uses a published amd64 BYOM image identified by
`REGISTRY/IMAGE@sha256:DIGEST`. Slurm also accepts a prepared SIF. Build and
publish from the [server Dockerfile](server/Dockerfile) in your build
environment. The BYOM runner needs no local Docker, Podman, or Isabelle.

The deployer's computer is fully trusted. Provider tokens are short-lived
and disposable. Account setup and BYOM can run in separate environments.
On Fly and Hetzner, `--token FILE` takes precedence over `FLY_API_TOKEN` or
`HCLOUD_TOKEN`. BYOM prompts if neither is available. Slurm uses SSH.

### Desired state

| Command | State it ensures |
| --- | --- |
| `deploy IMAGE` | A release is installed or staged on the target. A new deployment is stopped. Stop an existing instance before changing its release. |
| `start` | The deployed release is serving. BYOM prints verified credentials. |
| `stop` | The deployment is offline and ready for another start. |
| `diagnose` | Reports current status and checks a running instance. |
| `destroy` | Removes a stopped deployment and the resources BYOM created for it. |

The provider guides cover setup and commands. Run BYOM from the repository root.
Omitting the command defaults to `start`. Run `./byom PROVIDER --help` for options.

You can repeat the desired-state commands. `start` and `stop` work against
the staged release. `deploy` and `destroy` manage the installation.
Provider accounts, published images, and access credentials are inputs to
this lifecycle.

BYOM prints the WebSocket URL and native password after verifying the client
connection. On Slurm, keep `start` running while using its local SSH tunnel.
Restarting Isabelle changes its password and ends active
sessions and proof jobs.

```text
=== Isabelle server credentials ===
URL=wss://YOUR-HOST/isabelle
PASSWORD=...
===================================
```

## Diagnose an instance

Use the same provider access as for `start`. Fly and Hetzner check the native
server and public WebSocket endpoint, then print current credentials. Slurm
reports job state and its log path, and checks authentication through a
temporary SSH tunnel if Isabelle is ready.

```sh
./byom fly diagnose --token fly.token
./byom hetzner diagnose --token hetzner.token --ssh-key-file /path/to/deployment-key
./byom hpc diagnose
```

If Livebook closes about five seconds into authentication, run `diagnose` and check its
`ISABELLE_URL` and `ISABELLE_PASSWORD` secrets against the current credentials.
On Slurm, use `start JOB_ID` to reopen a tunnel to that specific job and get
the URL and password.

## Reference

The server reference covers the wire protocol, file placement, architecture,
and runtime configuration. [Server reference](server/README.md)

## Verification

The test guide covers local checks, live provider tests, and Elixir client
integration. [Test guide](test/README.md)

## License

[MIT](LICENSE) for original code and documentation. Isabelle, websocat, Caddy
and other upstream software retain their respective licenses.
