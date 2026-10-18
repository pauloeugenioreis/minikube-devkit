# minikube-devkit

A professional local environment for development, testing and DevOps automation on
[Minikube](https://minikube.sigs.k8s.io/), with **RabbitMQ, MongoDB, PostgreSQL, MySQL,
Redis, KEDA** and the **Kubernetes Dashboard** — ready-made scripts for **Windows, Linux
and macOS**.

> **Status:** early development. Prerequisite checks and installation (`doctor`,
> `install-prereqs`) work today with the `docker` driver; the cluster and services are
> coming next (see [Roadmap](#roadmap)).

## Quick start

**Linux / macOS**

```bash
./devkit.sh doctor            # read-only diagnostics
./devkit.sh install-prereqs   # install and configure what is missing
```

**Windows** (Windows PowerShell 5.1 or PowerShell 7+)

```powershell
Set-ExecutionPolicy -Scope Process Bypass   # only if scripts are blocked
.\devkit.ps1 doctor
.\devkit.ps1 install-prereqs
```

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

## Options

| Option (Bash) | Option (PowerShell) | Description |
|---|---|---|
| `-y`, `--yes` | `-Yes`, `-y`, `--yes` | Non-interactive: accept the default answer for every prompt |
| `-v`, `--verbose` | `-VerboseLog`, `--verbose` | Print the commands being executed |
| `--driver NAME` | `-Driver NAME` | Minikube driver (default `docker`) |

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

## Roadmap

- [x] Repository base, configuration and shared libraries (Bash + PowerShell)
- [x] Core CLIs and the `docker` driver on Linux, macOS and Windows
- [ ] Interactive setup wizard (`devkit up`): driver, resources and component selection
- [ ] Cluster, data services, KEDA and Kubernetes Dashboard
- [ ] Other drivers: kvm2, hyperv, podman, virtualbox, qemu, vfkit
- [ ] KEDA examples, operational commands, tests, CI and docs

## License

[MIT](LICENSE)
