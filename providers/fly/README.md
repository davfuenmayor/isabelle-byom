# Deploy to Fly

Fly account setup and BYOM deployment can happen on different computers or in
different shells. The account operator uses their Fly login; the BYOM runner
receives a deployment token. The runner can be local, in a container or in the
cloud. They need no shared filesystem, shell environment or saved login.

## Fly account setup

Run these commands in the account operator's environment, with
[flyctl](https://fly.io/docs/flyctl/install/) installed. First, log in:

```bash
fly auth login
```

This guide uses app `isabelle-byom`. For a new deployment, create it and select
its organization. Skip this command if the app already exists:

```bash
fly apps create isabelle-byom
```

### Choose machine resources

Resize existing Machines with `fly scale vm` or `fly scale memory`; resizing
restarts them. Currently, BYOM resets resources on every deployment according to
the settings in [fly.toml](fly.toml) (defaulting to **2 shared CPUs and 4 GB RAM**).

### Start an existing machine

For an existing app, list its Machines to find their IDs. Start the one you want
if it is stopped; this boots its installed image, including any previously
installed Isabelle. Skip startup for a new app: its first deployment creates
the Machine.

```bash
fly machine list --app isabelle-byom
fly machine start MACHINE_ID --app isabelle-byom
```

### Issue a token for BYOM

Create an app-scoped token and save the complete output, including its `FlyV1 `
prefix. `--expiry 1h` gives one hour; omitting it defaults to **20 years**
(`175200h`), per [Fly's documentation](https://fly.io/docs/security/tokens/).
The token authorizes deployment and administrative commands. Its expiry does
not stop Isabelle or affect clients already using the server:

```bash
fly tokens create deploy --app isabelle-byom --expiry 1h > fly.token
```

Supply this token to the BYOM runner as a file or through `FLY_API_TOKEN`.
For example, copy or mount `fly.token` into a container, or configure a cloud
runner's environment variable. The account operator's Fly login stays in their
own environment.

## Run BYOM

These commands run in the **BYOM runner's environment**, from the repository root.
It needs Linux or macOS, Bash, standard Unix utilities and `flyctl`.
**No interactive Fly login, local Docker/Podman daemon, or local Isabelle is required.**

BYOM uploads the build files using `fly deploy --remote-only`. Fly builds the
image remotely and installs it. An update restarts the Machine and ends its
sessions. Defaults are app `isabelle-byom` and region `fra`; override them with
`--app NAME` or `--region REGION`. The current resource-sizing limitation is
explained under [Choose machine resources](#choose-machine-resources).

If the runner receives a token file, pass its path with `--token`:

```bash
./byom fly --token fly.token
```

If `FLY_API_TOKEN` is already set in the runner's environment, omit the option.
An explicit `--token` file takes precedence. With neither, BYOM prompts:

```bash
./byom fly
```

## Diagnose an existing deployment

Run this in the BYOM runner to check the Machine, native server and public tunnel
and retrieve the current password. Token handling is the same as deployment;
this command does not rebuild, restart or resize the Machine:

```sh
./byom diagnose fly
```

If a connection closes during authentication, use the returned PASSWORD value
to update the Livebook secret. See [troubleshooting](../../README.md#diagnose-an-instance).

## Connection details

Progress goes to stdout. After public WSS authentication and echo succeed, BYOM
prints the URL and native server password last. Give these values to users;
they use neither the Fly login nor the deployment token. The server password
changes on restart:

```text
=== Isabelle server credentials ===
URL=wss://isabelle-byom.fly.dev/isabelle
PASSWORD=...
===================================
```

## Later Fly administration

Use the account operator's logged-in Fly CLI for these commands. To retrieve
and verify the current server credentials without deploying:

```sh
fly ssh console --app isabelle-byom -C '/opt/byom/credentials.sh wss://isabelle-byom.fly.dev/isabelle'
```

To stop a Machine while keeping the app and installed image:

```sh
fly machine stop MACHINE_ID --app isabelle-byom
```

To remove the app and its Machines permanently:

```sh
fly apps destroy isabelle-byom
```

[Boot tests](../../test/README.md#real-provider-boot-checks) reuse existing Machines
and restore their stopped state. The [project's operating assumptions](../../README.md#deploy) apply.
