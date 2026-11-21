# BYOM server reference

## Native protocol over WebSocket

The tunnel carries the Isabelle2026 TCP protocol over binary WebSocket messages.
The server adds optional file-placement commands. Clients maintain their own
versions, packages, dependencies and releases.

1. Connect to the exact `/isabelle` endpoint using HTTP/1.1 WebSocket Upgrade.
   Public deployments use **WSS with certificate and hostname verification**.
   Slurm uses loopback **WS through SSH**.
2. Send the native server password as the first framed message. Wait for native
   `OK` before sending commands. Authentication failure closes the connection.
3. Send ordinary Isabelle commands and receive ordinary native replies. Every
   WebSocket connection owns one TCP connection to the loopback-only server.
4. Use binary WebSocket messages. Concatenate payload bytes before parsing native
   framing: a WebSocket message can split a native message or contain several.
   Handle ping, pong, and close frames. Use ping for keepalives. An empty binary
   message signals EOF in the pinned relay.

All native messages use UTF-8. A short message is `CONTENT` followed by LF.
For a multiline message, a message exceeding 100 bytes, or content consisting
only of digits, send a decimal **UTF-8 byte count** followed by LF and exactly
that many bytes. Count the final LF after the content too. Parse both forms on
receive, regardless of how WebSocket frames are divided. After authentication,
`help` lists commands. `echo` returns the JSON value or YXML element it receives.
The example uses short messages.

```text
PASSWORD\n
help\n
echo {"message":"hello"}\n
```

Replies begin with `OK`, `ERROR`, `NOTE`, `FINISHED` or `FAILED`, optionally
followed by a space and a JSON value or a YXML element. An async command
acknowledges with `OK {"task":"UUID"}`. Match later `NOTE`, `FINISHED`, and
`FAILED` messages by the `task` field because commands can interleave. Inspect
the `ok` flag and diagnostics to tell whether a finished proof succeeded.

`session_start`, `use_theories` and `session_stop` are asynchronous. They start
a session, check its theories and stop it, respectively. Pass JSON arguments
and wait for the matching terminal reply after each call. See the Isabelle2026
system manual, “Isabelle server”, for the complete arguments and result schemas.
BYOM forwards these commands unchanged. Query `help` to discover optional commands.

```text
session_start {"session":"HOL"}
use_theories {"session_id":"UUID","master_dir":"SERVER_DIR","theories":["Example"]}
session_stop {"session_id":"UUID"}
```

### File placement

File commands are synchronous native commands after password authentication.
They accept UTF-8 text up to **8 MiB per write**, return server-side paths, reject
absolute paths, `..` traversal and symlinks, and atomically replace files. The
limit applies to decoded file content. Expected filesystem failures
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

The root is the session's temporary directory. Native `session_stop` removes
it, so writes racing with stop may fail. Use the returned parent directory for
`master_dir` in `use_theories`. These paths refer to the server's filesystem.

**Project sources** must exist before a session/build can use them.
`byom_create_project` returns `project_id` and a server-side `dir`.
Use the `project_id` attribute with `byom_write_project_file` and pass `dir` in native
`session_build`/`session_start` `dirs`. Retain the sources until every build and
session using them has stopped.

```text
byom_create_project
OK \x05\x06byom\x06project_id=BASE64_ID\x06dir=BASE64_DIR\x05\x05\x06\x05
byom_write_project_file \x05\x06file\x06project_id=UUID\x06path=dGVzdC50eHQ=\x05aGVsbG8=\x05\x06\x05
OK \x05\x06byom\x06path=BASE64_SERVER_PATH\x05\x05\x06\x05
```

The caller owns cleanup, including failure paths. Projects live until removal
or server exit. Unknown or released handles return `ERROR`. Crashes can leave
temporary files.

After all builds and sessions using a project have stopped, release it with
`byom_remove_project`.

```text
byom_remove_project \x05\x06project\x06project_id=UUID\x05\x05\x06\x05
OK \x05\x06byom\x06removed=BASE64_ID\x05\x05\x06\x05
```

## Architecture

The deployer uses provider credentials to manage the instance. Clients use
the native password to access it. That password is shared across clients,
so deploy an instance for users who trust one another.

The image pins Isabelle2026 and checksum-verifies websocat. websocat runs as a
separate process in the same container. An external Isabelle component registers
file commands in the Isabelle JVM. Fly terminates TLS at its edge. Hetzner
uses Caddy for TLS. Slurm forwards a loopback WebSocket through SSH.

The launcher discovers Isabelle's writable user configuration, captures startup
metadata privately, starts the relay after native startup, and terminates its
process tree on signal or child exit. Shutdown escalates to SIGKILL after
a grace period. Tini reaps orphans. Disconnect cancels connection-owned tasks.
Sessions remain available until explicitly stopped or until the server exits.

```text
Fly and Hetzner: client → WSS/TLS edge → websocat → Isabelle TCP server
Slurm:           client → SSH tunnel  → websocat → Isabelle TCP server
```

### Runtime configuration

The provider configuration sets resource and restart policies. When several
relays share a network namespace, give each relay its own port.

The provider defaults cap the JVM heap at 1 GiB. A Fly Machine with 2 shared
CPUs and 4 GiB RAM ran the example notebook, including its custom session
build. For two active HOL sessions, 4 vCPUs, 8 GiB RAM, and a 2 GiB JVM heap
(`-Xmx2g`) are a starting estimate. Measure with your theories and leave RAM
for Poly/ML, external provers, JVM overhead, and the OS.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | WebSocket relay port |
| `BYOM_BIND_ADDRESS` | `0.0.0.0` | Relay listener address |
| `ISABELLE_SERVER_PORT` | `8081` | Native loopback port. Use `0` for an ephemeral port. |
| `BYOM_JAVA_OPTIONS` | Isabelle default | Runtime JVM budget, set by provider configuration |
| `BYOM_THREADS` | Isabelle default | Default Isabelle proof threads |
| `BYOM_INFO` | `/tmp/byom-server.info` | Private startup metadata file. Use a unique path for concurrent jobs. |
| `BYOM_START_TIMEOUT` | `120` | Seconds to wait for native startup |
| `BYOM_STOP_TIMEOUT` | `10` | Grace period in seconds before killing unresponsive descendants |
