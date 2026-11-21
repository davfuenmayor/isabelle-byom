# Run BYOM on Slurm

Set `IMAGE` to a pinned OCI image or an absolute path to a shared SIF.
Deploy stages a SIF in your shared workspace. Start runs it in a Slurm job
and opens a local tunnel. Stop releases the job. Destroy removes the
deployment directory after the job has stopped.

```sh
./byom hpc deploy "$IMAGE"
./byom hpc start
./byom hpc diagnose
./byom hpc stop
./byom hpc destroy
```

## One-time setup

1. Install OpenSSH and `websocat` on the computer running BYOM. Configure SSH
   access to the login host and compute nodes, including any jump host. BYOM
   uses the batch hostname returned by Slurm, so OpenSSH must know how to
   reach that name and forward TCP ports. Sign in manually first if your
   site requires interactive authentication. Verify access by running
   `ssh -o BatchMode=yes cluster-login true`, using your own login alias.
2. Publish an amd64 image built from the BYOM Dockerfile or place a prebuilt
   SIF on shared storage. BYOM converts a pinned OCI reference to a SIF in a
   temporary Slurm job. If compute nodes cannot reach the registry, use
   a prebuilt SIF. [BYOM Dockerfile](../../server/Dockerfile)
3. Save the login alias in
   `${XDG_CONFIG_HOME:-$HOME/.config}/isabelle-byom/hpc.conf`. Choose an
   existing shared `work-dir` or use the default, `$WORK` on the login node
   with `$HOME` as fallback. BYOM stages the release and keeps job files in
   `.byom` under this directory.

```ini
login=cluster-login
image=/shared/images/isabelle-byom.sif
work-dir=/shared/your-directory/isabelle-byom
```

The file uses literal `key=value` lines. Leave values unquoted, and put
comments on lines starting with `#`. For another cluster, save a separate file
and put `--config FILE` before the command, for example
`./byom hpc --config FILE start`.

You can save `image` as the default input for `deploy`. For one-off runs, use
`./byom hpc deploy IMAGE --login HOST`. Command-line options take precedence,
followed by `BYOM_HPC_LOGIN` and `BYOM_HPC_IMAGE`, then the config file.
An absolute SIF path should refer to an immutable release.

### Site settings

BYOM defaults to four CPUs and one hour. Add `partition`, `account`, `qos`,
`cpus`, `mem`, or `walltime` to the file when the site requires them.
Partition, account, QoS, and memory use Slurm defaults unless specified.
Add `apptainer-module=NAME` if Apptainer needs a module loaded on the compute
node, or `srun=true` if your site launches applications as job steps.
Use `SBATCH_*` variables in the remote login environment for other Slurm
settings.
See `./byom hpc --help` for all options. [Slurm sbatch reference](https://slurm.schedmd.com/sbatch.html)

## Use the tunnel

Start prints the job ID, queue status, and log path. After verifying the
tunnel, it prints a loopback WebSocket URL and the native Isabelle password.
Use these in your client. Run BYOM on the same host and network as that client.
For Livebook, this is the machine or container running its Elixir runtime.

Ctrl+C closes the tunnel. The job continues until its walltime or until you
stop it. Run `./byom hpc start JOB_ID` to reopen the tunnel to that job. If
the job has ended, BYOM exits with an error. Without an ID, commands select
jobs in the configured workspace. If there are several, BYOM lists their IDs.
An explicit ID also works for jobs started before the workspace layout changed.
BYOM uses the working directory recorded by Slurm when
reusing an existing job. Stop releases the allocation and removes that job’s
log from a managed deployment. Destroy also removes the staged image and
managed workspace files. The shared input SIF stays available for later use.

If startup fails, run `./byom hpc diagnose` to see the job state and Slurm log
path. If Isabelle is ready, diagnosis checks it through a temporary SSH tunnel.
If SSH fails, check the route or host key for the printed node name.
