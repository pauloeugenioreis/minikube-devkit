# Linux

Tested on Ubuntu/Debian (apt), Fedora/RHEL family (dnf/yum), Arch (pacman) and openSUSE
(zypper), on amd64 and arm64.

## Quick start

```bash
git clone <this repo> && cd minikube-devkit
./devkit.sh up
```

Run devkit as your **regular user**. It calls `sudo` only for the steps that need it
(installing packages, starting services, adding you to groups) and tells you why.

## Drivers

| Driver | What devkit installs/configures |
|---|---|
| `docker` (default) | Docker Engine from Docker's repository (falls back to the distro package), enables the service, adds you to the `docker` group |
| `kvm2` | QEMU/KVM and libvirt, starts libvirt, adds you to `libvirt`, activates the `default` network |
| `qemu` | QEMU; KVM acceleration through `/dev/kvm` (`kvm` group) |
| `podman` | Podman and a sudoers rule that allows only `podman` without a password (minikube runs `sudo -n podman`); asks first |
| `virtualbox` (amd64) | VirtualBox, its kernel driver and the `vboxusers` group |

## Re-login after joining a group

Joining `docker`, `libvirt`, `kvm` or `vboxusers` only takes effect in a new login
session. devkit stops with exit code `10` and explains it; log out and back in (or run
`newgrp docker` in the current terminal) and run the same command again — it resumes.

## WSL 2

Inside a WSL 2 distribution devkit behaves as on Linux. Without systemd it uses
`service docker start`. Running devkit from Windows (`devkit.ps1`) with Docker Desktop is
usually simpler.
