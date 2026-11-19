# Isabelle BYOM (Bring Your Own Machine for Isabelle)

BYOM deploys an Isabelle server to infrastructure you control. Users
connect with a WebSocket URL and the native server password. The server supports
clients that implement the protocol below. Client and server builds, dependencies
and releases are independent.

## Deploy

### Local requirements

Use Linux or macOS with Bash and standard Unix utilities, plus these provider tools:

| Provider | Required on the deployer's computer | Where the image is built |
| --- | --- | --- |
| Fly | `fly` (flyctl) | Fly's remote build service, using `--remote-only` |
| Hetzner | `hcloud`, OpenSSH (`ssh`, `ssh-keygen`), tar | The Hetzner server, over SSH |

**Docker, Podman and Isabelle are not required locally.** The deployer uploads
build files and invokes the provider's CLI. Image builds and Isabelle's bundled
JDK/Scala tools run remotely. Hetzner installs Docker and Compose on its server
as needed. Deployment also requires no local Elixir/Erlang installation or
client SDK.

**Operating assumptions:** the deployer's computer is fully trusted. Secrets
and tokens are short-lived and disposable; their exposure is considered
inconsequential for this workflow. The examples use ordinary token files and
direct CLI commands. Set an expiry where supported (the Fly example uses one
hour), and revoke other tokens when finished.

Provider account setup and running BYOM are separate activities. They may happen
on different computers or in different shells. BYOM can run in a container or
cloud runner: supply its provider token and required access files in that
environment. The account operator's saved CLI login stays on their own computer.
The provider guides list the required inputs.

Starting a machine boots its installed system and services. Run BYOM to install
or update Isabelle. Follow the provider guide to prepare access and start an
existing stopped machine before deploying.

`--token FILE` reads a provider token from a file. Without it, Fly uses
`FLY_API_TOKEN` and Hetzner uses `HCLOUD_TOKEN` from the runner's environment.
If neither a file nor an environment token is supplied, BYOM prompts.
Hetzner requires an address choice: `--sslip` uses an IP-based public DNS name,
or `--hostname HOST` uses your own domain. Caddy provides Hetzner's HTTPS;
Fly uses its platform TLS edge.

These commands run from the repository root. Each guide explains account setup, new deployments
and restoring access from another deployer computer. `./byom PROVIDER --help`
lists the available options:

| Provider | Prepare access | Deploy Isabelle |
| --- | --- | --- |
| [Fly](providers/fly/README.md) | Install `fly`, create or select an app, generate an app-scoped token | `./byom fly --token fly.token` |
| [Hetzner](providers/hetzner/README.md) | Install `hcloud`, create or select a project, generate a Read & Write token | `./byom hetzner --sslip --token hetzner.token` |

Deployment progress goes to stdout. After an authenticated round trip through
the public endpoint, BYOM prints the URL and native server password in a final
block. Give both values to users. The password changes on restart; sessions
and proof jobs are not retained across server restarts:

```text
=== Isabelle server credentials ===
URL=wss://YOUR-HOST/isabelle
PASSWORD=...
===================================
```

## Diagnose an instance

`diagnose` checks an existing deployment without rebuilding, restarting or
resizing it. It checks provider access, Machine state, native TCP authentication,
file-command registration and the public TLS/WebSocket tunnel. It prints the
current connection credentials after those checks pass.

Run it in the BYOM runner with the same token inputs as deployment. Fly uses
`FLY_API_TOKEN`, Hetzner uses `HCLOUD_TOKEN`, and `--token FILE` takes precedence:

```sh
./byom diagnose fly --token fly.token
./byom diagnose hetzner --sslip --token hetzner.token --ssh-key-file /path/to/deployment-key
```

For Hetzner with your own domain, replace `--sslip` with `--hostname HOST`.
A stopped Machine is reported with a start command; diagnosis does not start it.
The checks are streamed over SSH, so an older installed image can be diagnosed
without redeployment.

If Livebook connects and then reports a close after about five seconds, check
its password. Isabelle closes connections without a reply for invalid passwords;
the WebSocket close handshake can account for that delay. Run `diagnose`, update
Livebook's `ISABELLE_URL` and `ISABELLE_PASSWORD` secrets with the returned values,
then rerun its connection cell. The native password changes on server restart.
A close during authentication can also indicate server failure; use the failed
check to locate the problem.

## Native protocol over WebSocket

The tunnel carries the Isabelle2026 TCP protocol over binary WebSocket messages.
The server adds optional file-placement commands. Clients maintain their own
versions, packages, dependencies and releases.

1. Connect to the exact `/isabelle` endpoint using HTTP/1.1 WebSocket Upgrade.
   Public deployments use **WSS with certificate and hostname verification**.
2. Send the native server password as the first framed message. Wait for native
   `OK` before sending commands. Authentication failure closes the connection.
3. Send ordinary Isabelle commands and receive ordinary native replies. Every
   WebSocket connection owns one TCP connection to the loopback-only server.
4. Use binary WebSocket messages. Concatenate payload bytes before parsing native
   framing: a WebSocket message can split a native message or contain several.
   Handle ping/pong/close; use ping for keepalives. Empty binary messages mean
   EOF in the pinned relay. No reconnect or replay is performed by the server.

All native messages use UTF-8. A short message is `CONTENT` followed by LF.
For a multiline message, a message exceeding 100 bytes, or content consisting
only of digits, send a decimal **UTF-8 byte count** followed by LF and exactly
that many bytes. Count the final LF after the content too. Parse both forms on
receive, regardless of how WebSocket frames are divided. After authentication,
`help` lists commands and `echo` returns its JSON argument. These examples use
the short-message form:

```text
PASSWORD\n
help\n
echo {"message":"hello"}\n
```

Replies begin with `OK`, `ERROR`, `NOTE`, `FINISHED` or `FAILED`, optionally
followed by a space and a JSON value or a YXML element. An async command first acknowledges with
`OK {"task":"UUID"}`. Match subsequent NOTE/FINISHED/FAILED messages by their
`task` field; other commands/tasks can interleave. A FINISHED reply is not by
itself a successful proof: inspect its `ok` flag and error diagnostics.

`session_start`, `use_theories` and `session_stop` are asynchronous. They start
a session, check its theories and stop it, respectively. Pass JSON arguments
and wait for the matching terminal reply after each call. See the Isabelle2026
system manual, “Isabelle server”, for the complete arguments and result schemas.
BYOM forwards them unchanged. Query `help` to discover optional commands;
unsupported commands must return an error rather than write files locally:

```text
session_start {"session":"HOL"}
use_theories {"session_id":"UUID","master_dir":"SERVER_DIR","theories":["Example"]}
session_stop {"session_id":"UUID"}
```

### File placement: two independent lifetimes

File commands are synchronous native commands after password authentication.
They accept UTF-8 text up to **8 MiB per write**, return server-side paths, reject
absolute paths, `..` traversal and symlinks, and atomically replace files. This
per-file check is not a transport allocation limit. Expected filesystem failures
produce native ERROR replies and leave the connection usable.

BYOM file arguments and successful replies use native YXML. Each successful
reply is an empty `byom` element with Base64-encoded attribute values. Decode
them as UTF-8. Isabelle sends errors in its usual reply format. Use matching
BYOM and `isabelle_elixir` versions for remote file operations.

For a write, send a `file` element with a raw `session_id` or `project_id`
UUID and a `path` attribute. Encode the UTF-8 path and file body separately
as standard Base64 without line breaks. This example writes `hello` to
`test.txt`. Each `\x05` or `\x06` represents a single byte. Apply the native
framing described above.

```text
byom_write_file \x05\x06file\x06session_id=UUID\x06path=dGVzdC50eHQ=\x05aGVsbG8=\x05\x06\x05
OK \x05\x06byom\x06path=BASE64_SERVER_PATH\x05\x05\x06\x05
```

**Session files** belong to an already started native session. Write them with
`byom_write_file`, using its session ID, a relative path and the source text.

The root is that session's temporary directory. Native `session_stop` removes
it; writes racing with stop may fail. Stopped roots are not recreated. Use the
returned parent directory for `master_dir` in `use_theories`. Connection close
is not session stop. Client-local filesystem calls do not access these paths.

**Project sources** must exist before a session/build can use them.
`byom_create_project` returns `project_id` and a server-side `dir`.
Use the `project_id` attribute with `byom_write_project_file` and pass `dir` in native
`session_build`/`session_start` `dirs`. Retain the sources until every build and
session using them has stopped:

```text
byom_create_project
OK \x05\x06byom\x06project_id=BASE64_ID\x06dir=BASE64_DIR\x05\x05\x06\x05
byom_write_project_file \x05\x06file\x06project_id=UUID\x06path=dGVzdC50eHQ=\x05aGVsbG8=\x05\x06\x05
OK \x05\x06byom\x06path=BASE64_SERVER_PATH\x05\x05\x06\x05
```

The caller owns cleanup, including failure paths. Disconnect does not remove
projects. Unknown/released handles return ERROR. Handles belong to the running
server and are not durable. Crashes can leave temporary files. There is no file
download API, binary upload API or persistent storage guarantee.

After all builds and sessions using a project have stopped, release it with
`byom_remove_project`:

```text
byom_remove_project \x05\x06project\x06project_id=UUID\x05\x05\x06\x05
OK \x05\x06byom\x06removed=BASE64_ID\x05\x05\x06\x05
```

## Architecture

- `server/`: shared amd64 image, runtime and Scala file component.
- `providers/`: provider-native deployment, TLS, resource budgets and guides.
- `test/`: SDK-independent protocol, filesystem, lifecycle and provider checks.

The client, server and deployer are separate projects/contracts. Provider
credentials stay in deployment. Native reasoning and file placement stay in the
server. Framing, proof APIs and task routing belong to clients. A shared native
password assumes trusted instance users; users are not isolated from one another.

The image pins Isabelle2026 and checksum-verifies websocat. websocat runs as a
separate process in the same container. An external Isabelle component registers
file commands in the existing JVM; it is not another service. Caddy is a TLS
edge. A separate tunnel container remains an option only for a concrete backend
benefit and must have private access to native loopback TCP.

The launcher discovers Isabelle's writable user configuration, captures startup
metadata privately, starts the relay after native startup, and terminates its
process tree on signal or critical child failure. Shutdown escalates to SIGKILL
after a grace period; Tini reaps orphans. No HA, session resumption, task replay
or connection-count watcher is provided. Disconnect cancels connection-owned
tasks without necessarily stopping sessions.

```text
Any native client → WSS → TLS edge → websocat → Isabelle TCP server
                                                  + file commands in its JVM
```

### Runtime configuration

The relay port must still be unique on a shared host. Runtime configuration is
writable separately from the installation. Resource defaults and restart rules
belong to provider configuration. Readiness/password retrieval is provider-specific
and verified through the public endpoint before credentials are printed.

Both providers currently cap the JVM heap at 1 GiB for small workloads. This
passed the example notebook, including its custom session build, on Fly with
2 shared CPUs and 4 GiB RAM; it is not a two-session capacity test. For two
active HOL sessions, start with 4 vCPUs, 8 GiB RAM and a 2 GiB JVM heap
(`-Xmx2g`), then measure the intended theories. This is our starting estimate;
[Isabelle's hardware guidance](https://isabelle.in.tum.de/) recommends 8 GB and
4 cores for medium applications. Large imports and external provers may need
more memory. The JVM heap limit covers neither ML prover processes nor all
JVM memory. Leave RAM for both and the OS. During testing, the 4 GiB Machine
suffered a confirmed OOM restart with Isabelle's default 4 GiB heap limit.
Restarts end sessions and change the native password.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Relay ingress on `0.0.0.0` |
| `ISABELLE_SERVER_PORT` | `8081` | Native loopback port; `0` requests a dynamic port discovered from metadata |
| `BYOM_JAVA_OPTIONS` | Isabelle default | Runtime JVM budget, set by provider configuration |
| `BYOM_INFO` | `/tmp/byom-server.info` | Private startup metadata file; use a unique path for concurrent jobs |
| `BYOM_START_TIMEOUT` | `120` | Seconds to wait for native startup |
| `BYOM_STOP_TIMEOUT` | `10` | Grace period in seconds before killing unresponsive descendants |

## Verify and license

See [test/README.md](test/README.md) for local and real-provider verification.
Tests use the native protocol and the bundled Isabelle runtime, with no SDK or
Elixir prerequisite. Development test tools do not become deployer requirements.

[MIT](LICENSE) for original code and documentation. Isabelle, websocat, Caddy
and other upstream software retain their respective licenses.
