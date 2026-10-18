# macOS

Supported on Apple Silicon and Intel Macs, with the system bash (3.2) or a newer one.

## Quick start

```bash
git clone <this repo> && cd minikube-devkit
./devkit.sh up
```

devkit uses [Homebrew](https://brew.sh). If it is missing, devkit asks before installing it.

## Drivers

| Driver | What devkit installs/configures |
|---|---|
| `docker` (default) | Docker Desktop (default) or Colima — set `DEVKIT_DOCKER_RUNTIME_MACOS`. Colima's VM is sized for the cluster |
| `vfkit` | vfkit (Apple Virtualization framework) |
| `qemu` | QEMU (builtin user network; services are reached through port-forwards) |
| `podman` | Podman and a rootful `podman machine` sized for the cluster |
| `virtualbox` (Intel) | VirtualBox — allow its system extension in System Settings > Privacy & Security |
| `hyperkit` (Intel, deprecated) | HyperKit |

## Docker Desktop resources

With the `docker` driver the cluster cannot be larger than what Docker Desktop allows.
`up` detects this and offers to use the largest size that fits; to give it more, raise
CPUs/memory in Docker Desktop > Settings > Resources.

On the first launch of Docker Desktop, accept its terms in the window that opens; devkit
waits for the engine to be ready.
