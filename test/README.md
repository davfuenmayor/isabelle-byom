# Verification

BYOM tests require no SDK, client checkout or Elixir. Test tools below are
**development requirements**, not additions to the deployer's prerequisites.

## Command and credential checks (no cloud)

These run the real CLI against stateful provider fixtures. They compare
resource snapshots before and after `deploy`/`destroy` and `start`/`stop`.
They also cover repeated requests, foreign resources, and failure handling.
The Fly tests require `jq`. ShellCheck is optional.

```sh
shellcheck -x byom providers/common.sh providers/*/*.sh server/*.sh test/*.sh
bash test/deploy.sh
bash test/hetzner.sh
bash test/hpc.sh
bash test/credentials.sh
bash test/diagnose.sh
```

## Runtime and filesystem checks (no cloud)

`test/lifecycle.sh` runs on Linux using the same Bash/procps tools as the server
image. It injects setup failure, hung configuration discovery, startup timeout,
relay failure, and SIGTERM. Mock children and detached descendants ignore TERM. Every path must remove
private runtime state, escalate to KILL and finish within its test deadline.
It also checks dynamic native-port discovery.

```sh
bash test/lifecycle.sh
```

With an installed Isabelle2026, run the Scala filesystem tests using Isabelle's
own compiler and JDK.

```sh
ISABELLE_TOOL=/path/to/Isabelle2026/bin/isabelle bash test/files.sh
```

These cover invalid paths, symlinks, oversized writes, non-directory parents,
replacement errors, concurrent nested-directory creation, atomic writes,
temporary-file cleanup and writes racing with native-style root deletion.

## Native protocol checks

The shell protocol test needs Bash 4.3+, the pinned websocat executable, `jq` and `base64`
as test tools. Use the release and checksum in the [Dockerfile](../server/Dockerfile)
when installing websocat on a test workstation.

```bash
export ISABELLE_URL=wss://YOUR-HOST/isabelle
read -r -s -p 'Native password: ' ISABELLE_PASSWORD; echo
export ISABELLE_PASSWORD
bash test/protocol.sh
```

This verifies native authentication, help/discovery, UTF-8 length framing,
project ownership/release, path rejection, HOL startup/proof checking, writes
racing with session stop and errors after release. It parses native replies
without an SDK and cleans up its own sessions/projects on assertion failure.
Use a dedicated test instance with adequate proof resources. Local disposable
instances can use `ws://`. Public endpoints use certificate-verified WSS.
For Slurm, run the same protocol suite against the URL printed by
`./byom hpc start` while the tunnel is open.

## Real-provider boot checks

Authenticate the provider CLI first. Pass an **existing instance**. These tests
check the currently
installed image, TLS and current credentials after boot, then execute the native
protocol suite and reject an invalid password. On exit, the test stops resources
it started and restores the Fly Machine's original routing state.

```sh
bash test/boot.sh fly isabelle-byom EXISTING-MACHINE-ID
bash test/boot.sh hetzner EXISTING-SERVER DEPLOYMENT-SSH-KEY PUBLIC-HOSTNAME
```

Hetzner requires the original key and its matching `.known_hosts` file. Strict
host-key verification is retained. Use the provider deployer to install a changed
image before claiming that image has passed the boot test. Mock CLI checks
cannot establish real provider, certificate or sandbox compatibility.

## Live Fly lifecycle

Use an empty Fly app with public ingress and a pinned BYOM image. Run
`deploy` then `destroy`, and confirm the app’s Machine inventory and IPs
match the starting state. Deploy again, run `start` and the protocol tests,
then run `stop`. Confirm the same Machine, configuration, and image are
staged in the stopped state. Finish with `destroy` to remove the test
Machine. [Fly setup](../providers/fly/README.md)

## Client integration checks

The [client and notebook checks](client/README.md) use a sibling
`isabelle_elixir` checkout and a matching BYOM instance.
