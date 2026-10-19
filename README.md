# minikube-devkit

A professional local environment for development, testing and DevOps automation on
[Minikube](https://minikube.sigs.k8s.io/), with **RabbitMQ, MongoDB, PostgreSQL, MySQL,
Redis, KEDA** and the **Kubernetes Dashboard** — ready-made scripts for **Windows, Linux
and macOS**.

> **Status:** `up` is tested end to end on Linux with the `docker` driver (Bash and
> PowerShell entrypoints); other drivers and platforms install and validate their
> prerequisites and are covered by unit tests in CI.

Guides: [Linux](docs/linux.md) · [macOS](docs/macos.md) · [Windows](docs/windows.md) ·
[Services](docs/services.md) · [KEDA examples](docs/keda.md) ·
[Troubleshooting](docs/troubleshooting.md)

## Quick start

**Linux / macOS**

```bash
./devkit.sh up                # wizard + prerequisites + cluster + services
./devkit.sh doctor            # read-only diagnostics
```

**Windows** (Windows PowerShell 5.1 or PowerShell 7+)

```powershell
Set-ExecutionPolicy -Scope Process Bypass   # only if scripts are blocked
.\devkit.ps1 up
.\devkit.ps1 doctor
```

## Setup wizard

`up` (or `configure`, which only runs the wizard) asks a few questions — press Enter to
accept the default shown in brackets:

```
Select Minikube driver:
  1) docker       Docker containers (recommended) (default)
  2) kvm2         KVM virtual machine
  ...
Choice [1]:

Minikube resources (host: 12 CPUs, 32000 MB RAM, 210 GB free disk)
  CPUs [4]:
  Memory (MB) [8192]:
  Disk size (GB) [40]:

Install Kubernetes Dashboard? [Y/n]:
Install RabbitMQ?             [Y/n]:
...
Proceed? [Y/n]:
```

- Only drivers supported by your OS/CPU are listed.
- Default resources come from `config/devkit.env`, capped at half of your machine.
  Values below the minimum (2 CPUs, 4096 MB, 20 GB) or above what the machine has are
  rejected; more than 75% of the RAM asks for confirmation.
- With the `docker` driver, if Docker Desktop/Colima has less CPU or memory than
  requested, devkit offers to use the largest size that fits.
- Answers are saved to `config/devkit.env`; the next run offers
  `Use saved configuration? [Y/n]` (`--reconfigure` asks everything again).

## What you get

At the end of `up`, devkit prints how to reach everything it installed (only the
components you selected):

| Resource | URL / Endpoint | Credentials |
|---|---|---|
| Kubernetes Dashboard | `http://localhost:15671` | (no login) |
| RabbitMQ Management | `http://localhost:15672` | `guest` / `guest` |
| RabbitMQ AMQP | `amqp://guest:guest@localhost:5672/` | `guest` / `guest` |
| MongoDB | `mongodb://devkit:devkit@localhost:27017/devkit?authSource=admin` | `devkit` / `devkit` |
| PostgreSQL | `postgresql://devkit:devkit@localhost:5432/devkit` | `devkit` / `devkit` |
| MySQL | `mysql://devkit:devkit@localhost:3306/devkit` | `devkit` / `devkit` (root: `devkit`) |
| Redis | `redis://:devkit@localhost:6379` | password: `devkit` |
| KEDA | namespace `keda` (operator running) | - |

- In the terminal this is a bordered table; when the window is too narrow for it,
  each resource is printed as its own block instead, so lines never wrap.
- The URLs work right away: port-forwards run in background and restart themselves if
  a pod restarts (`forward start|stop|restart|status`).
- If a local port is busy, the next free one is used and shown in the table.
- `info` prints the table again (`--no-secrets` / `-NoSecrets` masks passwords).
- Data services run in the `devkit-data` namespace as StatefulSets with persistent
  volumes, so data survives `down`/`up`. `destroy` deletes the cluster and its data.
- Images, versions, ports and credentials are all set in `config/devkit.env`; the
  manifests in [`k8s/`](k8s/) are templates rendered from it.

## What `install-prereqs` does

Every dependency goes through **check → install → configure → verify**. Nothing is
installed before you see the full list and confirm it.

| Dependency | How it is installed |
|---|---|
| minikube, kubectl, helm | Official release binaries, verified with SHA-256. Installed to `/usr/local/bin` (Linux/macOS) or `%LOCALAPPDATA%\minikube-devkit\bin` (Windows) |

### Drivers

The wizard only lists the drivers supported by your OS and CPU:

| Driver | Linux | macOS | Windows | What devkit sets up |
|---|:-:|:-:|:-:|---|
| `docker` (default) | ✔ | ✔ | ✔ | Linux: Docker Engine (Docker repo or distro package), service, `docker` group. macOS: Docker Desktop or Colima (Homebrew). Windows: WSL 2 + Docker Desktop (winget/Chocolatey), `docker-users` group |
| `kvm2` | ✔ | | | KVM + libvirt, `libvirt` group, libvirt `default` network |
| `qemu` | ✔ | ✔ | | QEMU; KVM acceleration on Linux (`kvm` group) |
| `podman` (experimental) | ✔ | ✔ | ✔ | Linux: passwordless `sudo podman` rule (asks first). macOS/Windows: rootful `podman machine` sized for the cluster |
| `virtualbox` | ✔ amd64 | ✔ Intel | ✔ amd64 | VirtualBox, kernel driver and `vboxusers` group on Linux |
| `vfkit` | | ✔ | | vfkit (Apple Virtualization framework) |
| `hyperkit` (deprecated) | | ✔ Intel | | HyperKit |
| `hyperv` | | | ✔ Pro/Enterprise | Hyper-V feature (reboot), `Hyper-V Administrators` group (re-login) |

Every VM driver also checks that CPU virtualization (VT-x/AMD-V) is enabled.

### Versions and updates

`DEVKIT_MINIKUBE_VERSION`, `DEVKIT_KUBECTL_VERSION` and `DEVKIT_HELM_VERSION` default to
`latest`: the newest release is resolved on every run. When an older copy is installed,
devkit asks before replacing it:

```
Update minikube v1.38.1 to the latest v1.39.0? [Y/n]:
```

Answering yes uninstalls the old copy with the tool that installed it (Homebrew, snap,
apt/dnf/pacman, Chocolatey, Scoop, winget, or the plain file) and installs the new one.
Set an exact version (e.g. `v1.38.1`) to pin a tool. Versions below `*_MIN_VERSION` must
be updated.

Docker, Podman and VirtualBox are updated through the package manager that installed
them: `DEVKIT_DOCKER_VERSION`, `DEVKIT_PODMAN_VERSION` and `DEVKIT_VIRTUALBOX_VERSION`
are `latest` (offer available updates) or `current` (never offer). `doctor` reports
available updates without changing anything.

Steps that need a **re-login or reboot** (joining the `docker` group, enabling WSL 2) are
recorded in `.devkit/state`; run the same command again afterwards and it continues where
it stopped.

## Commands and options

| Command | Description |
|---|---|
| `up` | Setup wizard, prerequisites, cluster, components, KEDA examples, port-forwards and access table |
| `configure` | Setup wizard only |
| `status` | Cluster, pods, volumes, KEDA ScaledObjects and port-forwards |
| `info` | URLs and credentials of the installed components |
| `forward start\|stop\|restart\|status` | Manage the background port-forwards |
| `logs <name> [-f]` | Logs of a component (`postgresql`, `keda`, `redis-worker`, …) |
| `shell <service>` | Open `psql`, `mysql`, `mongosh`, `redis-cli` (or a shell for RabbitMQ), already authenticated |
| `reset <service>` | Recreate a data service with an empty volume |
| `examples deploy\|remove\|produce` | Manage the [KEDA examples](docs/keda.md) |
| `test smoke\|keda\|unit\|all` | Health checks, KEDA 0→N→0 autoscaling test, offline unit tests |
| `down` | Stop port-forwards and the cluster (data is kept) |
| `destroy` | Delete the cluster and all its data, then optionally uninstall everything devkit installed |
| `uninstall` | Remove only what devkit installed (binaries, packages, system files, minikube cache when no other profile exists) |
| `doctor` | Read-only diagnostics: prerequisites, resources, ports, network |
| `install-prereqs` | Install and configure what the selected driver needs |

| Option (Bash) | Option (PowerShell) | Applies to | Description |
|---|---|---|---|
| `-y`, `--yes` | `-Yes`, `-y`, `--yes` | all | Non-interactive: accept the default answer for every prompt |
| `-v`, `--verbose` | `-VerboseLog`, `--verbose` | all | Print the commands being executed |
| `--driver NAME` | `-Driver NAME` | all but `version` | Minikube driver |
| `--cpus N` | `-Cpus N` | `up`, `configure` | CPUs for the minikube node |
| `--memory MB` | `-Memory MB` | `up`, `configure` | Memory for the minikube node |
| `--disk GB` | `-Disk GB` | `up`, `configure` | Disk size for the minikube node |
| `--services LIST` | `-Services LIST` | `up`, `configure` | Components to install: `all`, `none` or e.g. `postgresql,redis,keda` |
| `--reconfigure` | `-Reconfigure` | `up`, `configure` | Ask every question again |

Example for CI:

```bash
./devkit.sh up --yes --driver docker --cpus 2 --memory 4096 --services postgresql,redis,keda
```

## Configuration

All settings live in a single, committed file: [`config/devkit.env`](config/devkit.env).
Edit it directly; the setup wizard also saves your answers there.

For a one-off override without touching the file, set an environment variable with the
same name — it takes precedence:

```bash
DEVKIT_CPUS=6 DEVKIT_MEMORY_MB=12288 ./devkit.sh doctor
```

> The credentials in `devkit.env` are for **local development only**. Never reuse them
> anywhere else.

## Project layout

```
devkit.sh             # entrypoint for Linux and macOS
devkit.ps1            # entrypoint for Windows
config/devkit.env     # single configuration file (shared)
k8s/                  # manifest templates per component (shared)
helm/                 # Helm values, e.g. KEDA (shared)
examples/             # KEDA examples: worker image and ScaledObjects (shared)
tests/unit/           # offline unit tests (unix.sh, windows.ps1)
docs/                 # per-OS guides, services, KEDA, troubleshooting
scripts/unix/         # Bash implementation (Linux + macOS)
scripts/windows/      # PowerShell implementation (Windows)
  lib/                # logging, config, prompts, package managers, state
  deps/               # dependency runner, core CLIs, drivers/
  cluster/            # minikube lifecycle, components, port-forwards, access table
  commands/           # one file per CLI command
```

Both implementations share the same layout and behaviour; Kubernetes manifests and Helm
values are shared by both.

## Roadmap

- [x] Repository base, configuration and shared libraries (Bash + PowerShell)
- [x] Core CLIs and the `docker` driver on Linux, macOS and Windows
- [x] Interactive setup wizard (`devkit up`): driver, resources and component selection
- [x] Cluster, data services, KEDA and Kubernetes Dashboard
- [x] Other drivers: kvm2, hyperv, podman, virtualbox, qemu, vfkit, hyperkit
- [x] `latest` versions with update prompts
- [x] KEDA examples, operational commands, tests, CI and docs
- [x] `destroy` / `uninstall` remove what devkit installed

## Development

```bash
./devkit.sh test unit                      # Bash unit tests
pwsh -File tests/unit/windows.ps1          # PowerShell unit tests
shellcheck -x devkit.sh
pwsh -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
```

CI (GitHub Actions) runs the linters, the unit tests on Linux, macOS (bash 3.2) and
Windows (PowerShell 5.1 and 7), and an end-to-end `up` + `test smoke` + `test keda` on
Linux.

## License

[MIT](LICENSE)
