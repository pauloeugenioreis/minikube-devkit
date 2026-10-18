# Kubernetes manifests

Shared by `devkit.sh` and `devkit.ps1`. Each component lives in its own folder:

| File | Purpose |
|---|---|
| `manifest.yaml` | Service, StatefulSet (and ConfigMaps) for the component |
| `credentials.env` | Keys of the `<component>-credentials` Secret, one `KEY=value` per line |

Both files are **templates**: every `${DEVKIT_*}` placeholder is replaced with the value
from `config/devkit.env` (or an environment variable with the same name) before the file
is applied. Other `$VARS` are left untouched, so container commands can still use the
environment variables of the pod.

The Secret is created with `kubectl create secret generic --from-env-file`, so values
are used literally (no quoting or escaping needed).

Databases read their credentials only on the first start, when the volume is empty.
Changing a password afterwards requires resetting that service's data.
