# Windows

Supported on Windows 10/11 with **Windows PowerShell 5.1** (built in) or PowerShell 7.

## Quick start

```powershell
git clone <this repo>; cd minikube-devkit
Set-ExecutionPolicy -Scope Process Bypass   # only if scripts are blocked
.\devkit.ps1 up
```

Run it from a **regular** (not elevated) terminal. When a step needs administrator
rights (enabling WSL 2 or Hyper-V, adding you to a group, Chocolatey) devkit asks for a
single UAC confirmation for that step.

Tools are installed into `%LOCALAPPDATA%\minikube-devkit\bin`, which devkit adds to your
user PATH. Packages come from **winget** (App Installer), with Chocolatey as fallback.

## Drivers

| Driver | What devkit installs/configures |
|---|---|
| `docker` (default) | WSL 2, Docker Desktop, the `docker-users` group, starts Docker Desktop |
| `hyperv` | The Hyper-V feature (Pro/Enterprise/Education) and the `Hyper-V Administrators` group |
| `virtualbox` (amd64) | VirtualBox (slower when Hyper-V is also enabled) |
| `podman` | WSL 2, Podman and a rootful `podman machine` sized for the cluster |

## Reboots and re-logins

Enabling WSL 2 or Hyper-V needs a **restart**; joining `docker-users` or
`Hyper-V Administrators` needs a **sign out/in**. devkit records where it stopped
(`.devkit\state`), exits with code `10`, and continues when you run the same command again.

## Docker Desktop resources

Docker Desktop on WSL 2 can use what `%UserProfile%\.wslconfig` allows (by default half
of the RAM). If the requested cluster does not fit, `up` offers the largest size that
does. To raise the limit:

```ini
[wsl2]
memory=12GB
processors=6
```

Then run `wsl --shutdown` and restart Docker Desktop.
