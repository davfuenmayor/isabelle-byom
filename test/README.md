# Verification

BYOM tests require no SDK, client checkout or Elixir. Test tools below are
**development requirements**, not additions to the deployer's prerequisites.

## Command and credential checks (no cloud)

Bash and standard Unix utilities suffice; ShellCheck is an optional developer
lint tool. These run the real deployer with fake CLIs:

```sh
shellcheck -x byom providers/common.sh providers/*/*.sh server/*.sh test/*.sh
bash test/deploy.sh
bash test/hetzner.sh
bash test/credentials.sh
bash test/diagnose.sh
```

## Runtime and filesystem checks (no cloud)

`test/lifecycle.sh` runs on Linux using the same Bash/procps tools as the server
image. It injects setup failure, hung configuration discovery, startup timeout, relay failure and SIGTERM;
mock children and detached descendants ignore TERM. Every path must remove
private runtime state, escalate to KILL and finish within its test deadline.
It also checks dynamic native-port discovery.

```sh
bash test/lifecycle.sh
```

With an installed Isabelle2026, run the Scala filesystem tests using Isabelle's
own compiler/JDK. No separate Scala runtime or test framework is required:

```sh
ISABELLE_TOOL=/path/to/Isabelle2026/bin/isabelle bash test/files.sh
```

These cover invalid paths, symlinks, oversized writes, non-directory parents,
replacement errors, concurrent nested-directory creation, atomic writes,
temporary-file cleanup and writes racing with native-style root deletion.

## Native protocol checks

The shell protocol test needs Bash 4.3+, the pinned websocat executable, `jq` and `base64`
as test tools (the deployer itself remains compatible with macOS Bash). websocat is already included in the server image; use its pinned release
and checksum from `server/Dockerfile` when installing it on a test workstation.

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
instances can use `ws://`; public endpoints must use certificate-verified WSS.

## Real-provider boot checks

Authenticate the provider CLI first. These tests accept **existing resources**;
they do not create replacements or deploy an image. They check the currently
installed image, TLS and current credentials after boot, then execute the native
protocol suite and reject an invalid password. A resource started by the test
is stopped again on exit. Already running resources remain running.

```sh
bash test/boot.sh fly isabelle-byom EXISTING-MACHINE-ID
bash test/boot.sh hetzner EXISTING-SERVER DEPLOYMENT-SSH-KEY PUBLIC-HOSTNAME
```

Hetzner requires the original key and its matching `.known_hosts` file. Strict
host-key verification is retained. Use the provider deployer to install a changed
image before claiming that image has passed the boot test. Mock CLI checks
cannot establish real provider, certificate or sandbox compatibility.

## Client integration checks

The [client and notebook checks](client/README.md) use a sibling
`isabelle_elixir` checkout and a matching BYOM instance.
