# Services

All values come from `config/devkit.env`; the table shows the defaults.

| Component | Local endpoint | Credentials | In-cluster address |
|---|---|---|---|
| Kubernetes Dashboard | http://localhost:15671 | no login | `kubernetes-dashboard.kubernetes-dashboard` |
| RabbitMQ Management | http://localhost:15672 | guest / guest | `rabbitmq.devkit-data:15672` |
| RabbitMQ AMQP | amqp://guest:guest@localhost:5672/ | guest / guest | `rabbitmq.devkit-data:5672` |
| MongoDB | mongodb://devkit:devkit@localhost:27017/devkit?authSource=admin | devkit / devkit | `mongodb.devkit-data:27017` |
| PostgreSQL | postgresql://devkit:devkit@localhost:5432/devkit | devkit / devkit | `postgresql.devkit-data:5432` |
| MySQL | mysql://devkit:devkit@localhost:3306/devkit | devkit / devkit (root: devkit) | `mysql.devkit-data:3306` |
| Redis | redis://:devkit@localhost:6379 | password: devkit | `redis.devkit-data:6379` |
| KEDA | — | — | namespace `keda` |

- **Local endpoints** work through background port-forwards (`devkit forward ...`). If a
  port is busy, the next free one is used and shown by `devkit info`. See
  [Connecting from outside Kubernetes](../README.md#connecting-from-outside-kubernetes)
  for client examples.
- **In-cluster addresses** are for your own workloads running in minikube
  (`<service>.<namespace>.svc.cluster.local` also works).
- Data services are StatefulSets with persistent volumes in `devkit-data`: data survives
  `down`/`up`. `devkit reset <service>` recreates one with an empty volume; `destroy`
  deletes everything.

## Handy commands

```bash
./devkit.sh shell postgresql     # psql, already authenticated (also mysql, mongodb, redis, rabbitmq)
./devkit.sh logs mysql -f        # follow logs
./devkit.sh status               # pods, volumes, ScaledObjects, port-forwards
./devkit.sh test smoke           # authenticated check of every service
```

## Versions

| Image | Default | Notes |
|---|---|---|
| RabbitMQ | `rabbitmq:4.2-management-alpine` | `guest` may connect from other pods (`loopback_users = none`) |
| MongoDB | `mongo:7.0` | 8.x exits on Linux kernels 6.19 to 7.0.13 (SERVER-121912) |
| PostgreSQL | `postgres:18-alpine` | volume mounted at `/var/lib/postgresql` (works for 18+ and older) |
| MySQL | `mysql:8.4` | LTS |
| Redis | `redis:8.2-alpine` | AOF persistence enabled |

Databases read credentials only on their first start. After changing a password or a
major image version, run `devkit reset <service>`.
