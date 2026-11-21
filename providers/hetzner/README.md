# Deploy to Hetzner Cloud

Hetzner account setup and BYOM deployment can happen on different computers or
in different shells. The operator uses a local `hcloud` context. BYOM receives
a project token and, for an existing server, its SSH key. The runner can be local,
in a container or in the cloud with its own token and key files.

## Hetzner setup

Run these steps in the account operator's environment, with
[`hcloud`](https://github.com/hetznercloud/cli/releases/latest) installed.

### Select the project and configure hcloud

Open your existing project in [Hetzner Console](https://console.hetzner.com/), or
create one for a new deployment. Choose **Security → API tokens → Generate API
token → Read & Write** and save the token in `hetzner.token`. Project and token
creation happen in Console. [Hetzner token guide](https://docs.hetzner.com/cloud/api/getting-started/generating-api-token/)

Create a local `hcloud` context using that file. This saves access on the
operator's computer.

```bash
HCLOUD_TOKEN="$(cat hetzner.token)" hcloud context create isabelle-byom --token-from-env
```

Select the existing context if you already created it.

```sh
hcloud context use isabelle-byom
```

List the project's servers. A new project starts with an empty list.

```sh
hcloud server list
```

### Supply access to the BYOM runner

Copy or mount `hetzner.token` into the runner, or supply it as `HCLOUD_TOKEN`.
You can reuse the setup token or generate a separate runner token. Revoke
disposable tokens in Console when finished.

Supply a deployment SSH key and keep it for later access. The default private
key path for this server is `~/.ssh/isabelle-byom-isabelle-byom`. Generate a key
in the BYOM runner if you are setting up a new server.

```sh
ssh-keygen -t ed25519 -f ~/.ssh/isabelle-byom-isabelle-byom
```

Use a key available for SSH in batch mode. For an existing server, supply its
original key and matching `.known_hosts` file if available. Use
`--ssh-key-file PATH` for a different key path. A project token cannot recover
a lost private key. [Hetzner SSH key recovery](https://docs.hetzner.com/cloud/servers/how-to-rescue/change-ssh-key/)

## Run BYOM

Set `IMAGE` to a published amd64 BYOM image pinned by SHA-256 digest. BYOM
creates the VM, registers the key, installs Docker and Compose, and pulls the
image on the VM. It stages stopped containers and powers the new VM off.
The runner needs Bash, `hcloud`, OpenSSH, and standard Unix utilities including
tar. See the [runner requirements](../../README.md#local-requirements).

On the first deployment, choose `--sslip` for `IP.sslip.io` DNS or
`--hostname HOST` for a domain you control. For your own domain, point its A
record at the VM's public IPv4 address before starting Isabelle. Caddy
provides HTTPS. Later deployments reuse the saved hostname by default.

```sh
./byom hetzner deploy "$IMAGE" --sslip --token hetzner.token
./byom hetzner start --token hetzner.token
./byom hetzner diagnose --token hetzner.token
./byom hetzner stop --token hetzner.token
./byom hetzner destroy --token hetzner.token
```

New servers default to `isabelle-byom`, `fsn1`, and `cx23` with 2 shared vCPUs
and 4 GB RAM on Ubuntu 24.04 x86. Override with `--name`, `--location`, or
`--type`. Container limits live in [compose.yaml](compose.yaml).

Stop the VM before replacing its release or destroying the deployment.
Destroy removes the VM and its disk, plus the firewall and SSH key record
that BYOM labeled for the deployment. Keep the private key for future deployments.
Older deployments may have unlabeled firewall and key records. Hetzner bills
for powered-off VMs until deletion. [Hetzner billing FAQ](https://docs.hetzner.com/cloud/billing/faq/#do-you-bill-servers-that-are-off)

Give users the printed URL and native password.

## Later Hetzner administration

Use the operator's `hcloud` context and deployment SSH key. To inspect the server,
connect with that key. On the server, run `docker compose` from
`/opt/isabelle-byom/providers/hetzner`.

```sh
hcloud server ssh isabelle-byom -i /path/to/deployment-key
```

Use the operator context to inspect leftover records from older deployments.

```sh
hcloud firewall list
hcloud ssh-key list
hcloud primary-ip list
```

[Boot tests](../../test/README.md#real-provider-boot-checks) reuse existing servers
and restore their stopped state. The [project's operating assumptions](../../README.md#run-byom) apply.
