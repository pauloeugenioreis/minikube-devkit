# minikube-devkit

A professional local environment for development, testing and DevOps automation on
[Minikube](https://minikube.sigs.k8s.io/), with **RabbitMQ, MongoDB, PostgreSQL, MySQL,
Redis, KEDA** and the **Kubernetes Dashboard** — ready-made scripts for **Windows, Linux
and macOS**.

> **Status:** early development. The setup wizard and prerequisite installation work
> today with the `docker` driver; the cluster and services are coming next (see
> [Roadmap](#roadmap)).

## Quick start

**Linux / macOS**

```bash
./devkit.sh up                # setup wizard + prerequisites (+ cluster, soon)
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

## What `install-prereqs` does

Every dependency goes through **check → install → configure → verify**. Nothing is
installed before you see the full list and confirm it.

| Dependency | How it is installed |
|---|---|
| minikube, kubectl, helm | Official release binaries pinned in `config/devkit.env`, verified with SHA-256. Installed to `/usr/local/bin` (Linux/macOS) or `%LOCALAPPDATA%\minikube-devkit\bin` (Windows) |
| Docker (Linux) | Docker Engine from Docker's repository (apt/dnf/yum) or the distribution package (pacman/zypper); enables the service and adds you to the `docker` group |
| Docker (macOS) | Docker Desktop (default) or Colima via Homebrew (Homebrew is installed if missing, with your consent) |
| Docker (Windows) | Enables WSL 2, installs Docker Desktop with winget (Chocolatey fallback), adds you to `docker-users` and starts it |

Steps that need a **re-login or reboot** (joining the `docker` group, enabling WSL 2) are
recorded in `.devkit/state`; run the same command again afterwards and it continues where
it stopped.

## Commands and options

| Command | Description |
|---|---|
| `up` | Setup wizard, prerequisites and (soon) cluster + components |
| `configure` | Setup wizard only |
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
scripts/unix/         # Bash implementation (Linux + macOS)
scripts/windows/      # PowerShell implementation (Windows)
  lib/                # logging, config, prompts, package managers, state
  deps/               # dependency runner, core CLIs, drivers/
  commands/           # up, configure, doctor, install-prereqs
```

Both implementations share the same layout and behaviour; Kubernetes manifests and
Helm values (coming next) are shared by both.

## Roadmap

- [x] Repository base, configuration and shared libraries (Bash + PowerShell)
- [x] Core CLIs and the `docker` driver on Linux, macOS and Windows
- [x] Interactive setup wizard (`devkit up`): driver, resources and component selection
- [ ] Cluster, data services, KEDA and Kubernetes Dashboard
- [ ] Other drivers: kvm2, hyperv, podman, virtualbox, qemu, vfkit
- [ ] KEDA examples, operational commands, tests, CI and docs

## License

[MIT](LICENSE)
