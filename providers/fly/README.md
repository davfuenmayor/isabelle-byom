# Deploy to Fly

Fly account setup and BYOM deployment can happen on different computers or in
different shells. The operator uses their Fly login and hands a deployment
token to the BYOM runner.

## Fly account setup

Run these commands in the account operator's environment, with
`flyctl` installed. Log in first. [Fly CLI installation](https://fly.io/docs/flyctl/install/)

```bash
fly auth login
```

This guide uses app `isabelle-byom`. For a new deployment, create it and select
its organization. Skip app creation if the app already exists.

```bash
fly apps create isabelle-byom
```

### Set up public routing and a release

Allocate a shared IPv4 address for the app. Skip this step if the app
already has one. BYOM uses the app's routing for the Machine.

```sh
fly ips allocate-v4 --shared --app isabelle-byom
```

Publish a pinned BYOM image from your build environment. You can build and push
to Fly remotely without Docker by using the app's registry. Pass the resulting
`registry.fly.io/isabelle-byom@sha256:DIGEST` to BYOM.

```sh
fly deploy . --config providers/fly/fly.toml --app isabelle-byom --remote-only --build-only --push
```

Set CPU and memory for new Machines in [machine.json](machine.json). The
defaults are 2 shared CPUs and 4 GiB RAM.

### Issue a token for BYOM

Create an app-scoped token and save the complete output, including its `FlyV1 `
prefix. `--expiry 1h` gives one hour. Omitting it defaults to **20 years**
(`175200h`). The token authorizes BYOM administration. Users connect with the
native password, which is independent of token expiry. [Fly token documentation](https://fly.io/docs/security/tokens/)

```bash
fly tokens create deploy --app isabelle-byom --expiry 1h > fly.token
```

Supply this token to the BYOM runner as a file or through `FLY_API_TOKEN`.
For example, copy or mount `fly.token` into a container, or configure a cloud
runner's environment variable. The account operator's Fly login stays in their
own environment.

## Run BYOM

These commands run in the **BYOM runner's environment**, from the repository root.
The runner needs Linux or macOS, Bash, standard Unix utilities, `fly` and `jq`.
BYOM uses the supplied token with Fly's API, including Machine exec for
credential retrieval and diagnostics.

Set `IMAGE` to the pinned release. Deployment waits for Fly to prepare the
image and bring the Machine to its stopped state. Use
`--app NAME` to select another app or `--region REGION` to place a new Machine
outside `fra`.

```sh
./byom fly deploy "$IMAGE" --token fly.token
./byom fly start --token fly.token
./byom fly diagnose --token fly.token
./byom fly stop --token fly.token
./byom fly destroy --token fly.token
```

Stop before staging a different image or destroying the Machine. Destroy
removes the BYOM-owned Machine. The app, IP addresses, and published images
belong to account setup.

The public URL must route to one Machine because each running server has its
own password. If the app has several Machines, use `--instance ID` to select
one and stop the others. New Machines have proxy autostart disabled. BYOM cordons older Machines on
stop and restores routing on start. Older Machines can continue to use
`start`, `stop`, and `diagnose`. An operator can retire an old Machine using
the Fly CLI when migrating to the new deployment API.

Give users the printed URL and native password. For the default app, the URL
is `wss://isabelle-byom.fly.dev/isabelle`.

## Later Fly administration

Use the account operator's logged-in Fly CLI for permanent removal.

This removes the app and its Machines permanently.

```sh
fly apps destroy isabelle-byom
```

[Boot tests](../../test/README.md#real-provider-boot-checks) reuse existing Machines
and restore their stopped state. The [project's operating assumptions](../../README.md#run-byom) apply.
