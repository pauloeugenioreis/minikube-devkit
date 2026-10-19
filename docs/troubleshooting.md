# Troubleshooting

Start with:

```bash
./devkit.sh doctor     # prerequisites, resources, ports, network (read-only)
./devkit.sh status     # cluster, pods, volumes, ScaledObjects, port-forwards
```

| Symptom | What to do |
|---|---|
| Exit code `10` | A re-login or reboot is required (group membership, WSL 2, Hyper-V). Do it and run the same command again |
| "Docker can use only N MB" | Give Docker Desktop/Colima/WSL 2 more memory, or accept the smaller size `up` offers |
| apt: "Conflicting values set for option Signed-By" | Repaired automatically: devkit keeps one declaration of the repository and renames the others to `*.disabled` (or comments them out / sets `Enabled: no`). To undo, rename the file back |
| A port is "already in use" | devkit picks the next free port; `devkit info` shows the real one. Or change `DEVKIT_PORT_*` |
| URLs stopped answering | `devkit forward restart` (logs in `log/port-forward-<name>.log`) |
| A service shows `NOT READY` | `devkit logs <service>`; `kubectl --context devkit -n devkit-data describe pod <service>-0` |
| MongoDB restarts with "Linux kernel versions 6.19 and newer" | Use `mongo:7.0` (default) in `DEVKIT_IMAGE_MONGODB`, then `devkit reset mongodb` |
| Changed a password/major version but nothing changed | Databases initialize once: `devkit reset <service>` |
| "Recreate cluster to apply new resources?" | The cluster was created with other CPUs/memory/disk/driver. Answer `y` to recreate (data lost) or keep it |
| `.ps1` "cannot be loaded because running scripts is disabled" | `Set-ExecutionPolicy -Scope Process Bypass` in that terminal |
| `devkit.sh` fails with `$'\r': command not found` | The file got Windows line endings; `git checkout -- .` (the repo's `.gitattributes` keeps `.sh` as LF) |
| Want a clean slate | `devkit destroy` (asks whether to uninstall everything devkit installed) |

## Run logs

Every run of `devkit.sh` / `devkit.ps1` (except `shell`, `help` and `version`) saves
everything it printed, including prompts and answers, to
`log/devkit-<command>-<timestamp>.log`; the path is shown when a command fails.
The 50 newest run logs are kept. Attach the log when reporting a problem, but check it
first: the access table printed by `up`/`info` contains passwords.

On Linux/macOS, `minikube start` writes straight to the terminal so its download
progress bars render correctly; its output is not in the run log (use
`minikube logs -p devkit` instead).

Logs and state live in `log/` and `.devkit/` (both git-ignored).
