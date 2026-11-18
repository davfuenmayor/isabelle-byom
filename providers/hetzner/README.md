# Deploy to Hetzner Cloud

Hetzner account setup and BYOM deployment can happen on different computers or
in different shells. The operator uses a local `hcloud` context. BYOM receives
a project token and, for an existing server, its SSH key. The runner can be local,
in a container or in the cloud; it does not need the operator's context files.

## Hetzner setup

Run these steps in the account operator's environment, with
[`hcloud`](https://github.com/hetznercloud/cli/releases/latest) installed.

### Select the project and configure hcloud

Open your existing project in [Hetzner Console](https://console.hetzner.com/), or
create one for a new deployment. Choose **Security → API tokens → Generate API
token → Read & Write** and save the token in `hetzner.token`. Project and token
creation require Console; see the [official token guide](https://docs.hetzner.com/cloud/api/getting-started/generating-api-token/).

Create a local `hcloud` context using that file. This saves access on the
operator's computer, without exporting a token for later commands:

```bash
HCLOUD_TOKEN="$(cat hetzner.token)" hcloud context create isabelle-byom --token-from-env
```

If the context already exists, select it instead of creating it:

```sh
hcloud context use isabelle-byom
```

List the project's servers. The existing deployment should appear; an empty
list is expected for a new project:

```sh
hcloud server list
```

### Start an existing machine

Power on an existing stopped server using the operator's context. This boots
its installed system and containers. Skip this step for an already running
server or a new deployment; BYOM creates the new server:

```sh
hcloud server poweron isabelle-byom
```

### Supply access to the BYOM runner

Copy or mount `hetzner.token` into the runner, or supply it as `HCLOUD_TOKEN`.
The same project token can be used in both environments; a separate runner token
can also be generated in Console. Revoke disposable tokens there when finished.

For an existing server, also supply its deployment private key and matching
`.known_hosts` file if available. A project token cannot recover a lost private
key. For a new server, BYOM generates and registers its key automatically.

| Runner input | Value |
| --- | --- |
| Token | `HCLOUD_TOKEN` or a token-file path in the runner |
| Existing server | Name, default `isabelle-byom` |
| Existing server's SSH key | Private-key path in the runner |
| Address | `--sslip` or your hostname |

<details>
<summary>Recover a lost SSH key</summary>

Follow Hetzner's [SSH-key recovery procedure](https://docs.hetzner.com/cloud/servers/how-to-rescue/change-ssh-key/)
to install a replacement on the existing server. Adding a key to Console alone
does not change an existing server's `authorized_keys`.

Once the replacement works, use the operator's `hcloud` context to rename the
old cloud key record. BYOM can then register the replacement under the expected
name on its next run:

```sh
hcloud ssh-key update byom-isabelle-byom --name retired-byom-isabelle-byom
```

</details>

## Run BYOM

These commands run in the **BYOM runner's environment**, from the repository root.
It needs Linux or macOS, Bash, standard Unix utilities, `hcloud`, OpenSSH
(`ssh`, `ssh-keygen`) and tar. **No saved hcloud context, local Docker/Podman,
Compose or Isabelle installation is required.**

BYOM uses `hcloud` for cloud resources and SSH access. It uploads build files;
the server installs Docker/Compose if needed and builds the image there. An
image update ends existing Isabelle sessions. Caddy provides HTTPS remotely.

Choose `--sslip` for `IP.sslip.io` public DNS, or `--hostname YOUR-HOST` for a domain
you control. For your domain, point its A record at the server's IPv4 address.
Defaults for new servers are `isabelle-byom`, `fsn1`, `cx23`, 2 shared vCPUs and
4 GB RAM on Ubuntu 24.04 x86. Override with `--name`, `--location` or `--type`.
Existing servers are not resized. Container limits live in [compose.yaml](compose.yaml).

BYOM uses the runner's `HCLOUD_TOKEN`. An explicit `--token hetzner.token` reads
the file instead and takes precedence. With neither, BYOM prompts for a token.

For an existing server, pass its restored SSH key using its path in the runner:

```sh
./byom hetzner --sslip --ssh-key-file /path/to/deployment-key
```

For a new server, omit the key option. BYOM creates the server, firewall and key:

```sh
./byom hetzner --sslip
```

The generated key defaults to `~/.ssh/isabelle-byom-isabelle-byom`, with a matching
`.known_hosts` file. Keep those files outside disposable runners for future
updates and access. If SSH rejects restored key permissions, use `chmod 600 KEY_FILE`.

## Connection details

Progress goes to stdout. After public WSS authentication and echo succeed, BYOM
prints the URL and native server password last. Give these values to users;
they need neither the project token nor the SSH key. Passwords change on restart:

```text
=== Isabelle server credentials ===
URL=wss://YOUR-HOST/isabelle
PASSWORD=...
===================================
```

## Later Hetzner administration

Use the operator's `hcloud` context and deployment SSH key. To inspect the server,
connect with that key; on the server, use `docker compose` from
`/opt/isabelle-byom/providers/hetzner`:

```sh
hcloud server ssh isabelle-byom -i /path/to/deployment-key
```

To shut down the server while retaining its disk and deployment:

```sh
hcloud server shutdown isabelle-byom
```

For permanent removal, delete the server, firewall and cloud key, then check
for leftover deployment IPs. Server deletion removes its disk and certificates:

```sh
hcloud server delete isabelle-byom
hcloud firewall delete byom-isabelle-byom
hcloud ssh-key delete byom-isabelle-byom
hcloud primary-ip list
```

[Boot tests](../../test/README.md#real-provider-boot-checks) reuse existing servers
and restore their stopped state. The [project's operating assumptions](../../README.md#deploy) apply.
