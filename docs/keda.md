# KEDA examples

When KEDA is installed, devkit also deploys three autoscaling examples into the
`devkit-apps` namespace (all of them, whatever services you selected — a ScaledObject
whose service is missing simply reports not ready).

| Example | Trigger | Behaviour |
|---|---|---|
| `rabbitmq-worker` | RabbitMQ queue `devkit-jobs` length | 0 workers when empty; +1 per 5 waiting messages (max 10) |
| `redis-worker` | Redis list `devkit-jobs` length | same, for a Redis list |
| `cron-demo` | cron | 2 replicas during minutes 0–10, 20–30, 40–50 of every hour (UTC) |

The worker ([`examples/worker`](../examples/worker)) is a tiny Python program built
inside the cluster with `minikube image build`, so no registry is needed. Each message
"takes" one second.

## Try it

```bash
./devkit.sh examples produce rabbitmq 100
kubectl --context devkit -n devkit-apps get deploy rabbitmq-worker -w
```

You will see the Deployment go from 0 to several replicas and, about 30 seconds after
the queue is empty (`cooldownPeriod`), back to 0.

`./devkit.sh test keda` automates exactly this for RabbitMQ and Redis and fails if the
workers do not scale out and back to zero.

## Use it for your own workloads

Copy one of the manifests in [`examples/k8s`](../examples/k8s), point
`scaleTargetRef` to your Deployment and adjust the trigger. The
`TriggerAuthentication` objects show how to pass credentials from a Secret.
