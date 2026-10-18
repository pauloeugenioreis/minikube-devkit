"""KEDA example worker for minikube-devkit.

One small program, four modes (MODE environment variable):

  rabbitmq-consume  consume messages from the RabbitMQ queue QUEUE
  rabbitmq-produce  publish COUNT messages to QUEUE and exit
  redis-consume     pop items from the Redis list QUEUE
  redis-produce     push COUNT items to QUEUE and exit

Each consumed item "takes" WORK_SECONDS, so a backlog makes KEDA scale the
consumer Deployment out, and an empty queue lets it scale back to zero.
"""

import os
import socket
import sys
import time

MODE = os.environ.get("MODE", "")
QUEUE = os.environ.get("QUEUE", "devkit-jobs")
COUNT = int(os.environ.get("COUNT", "50"))
WORK_SECONDS = float(os.environ.get("WORK_SECONDS", "1"))
WORKER = socket.gethostname()


def log(message):
    print(f"[{WORKER}] {message}", flush=True)


def rabbitmq_channel():
    import pika

    params = pika.URLParameters(os.environ["AMQP_URL"])
    for attempt in range(30):
        try:
            connection = pika.BlockingConnection(params)
            channel = connection.channel()
            channel.queue_declare(queue=QUEUE, durable=True)
            return connection, channel
        except pika.exceptions.AMQPConnectionError as error:
            log(f"waiting for RabbitMQ ({attempt + 1}/30): {error}")
            time.sleep(2)
    sys.exit("RabbitMQ is not reachable")


def rabbitmq_consume():
    _, channel = rabbitmq_channel()
    channel.basic_qos(prefetch_count=1)

    def handle(ch, method, _properties, body):
        log(f"processing {body.decode()}")
        time.sleep(WORK_SECONDS)
        ch.basic_ack(delivery_tag=method.delivery_tag)

    channel.basic_consume(queue=QUEUE, on_message_callback=handle)
    log(f"consuming from queue {QUEUE}")
    channel.start_consuming()


def rabbitmq_produce():
    import pika

    connection, channel = rabbitmq_channel()
    for i in range(COUNT):
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE,
            body=f"job-{i + 1}".encode(),
            properties=pika.BasicProperties(delivery_mode=2),
        )
    connection.close()
    log(f"published {COUNT} messages to queue {QUEUE}")


def redis_client():
    import redis

    client = redis.Redis(
        host=os.environ["REDIS_HOST"],
        port=int(os.environ.get("REDIS_PORT", "6379")),
        password=os.environ.get("REDIS_PASSWORD") or None,
    )
    for attempt in range(30):
        try:
            client.ping()
            return client
        except redis.exceptions.ConnectionError as error:
            log(f"waiting for Redis ({attempt + 1}/30): {error}")
            time.sleep(2)
    sys.exit("Redis is not reachable")


def redis_consume():
    client = redis_client()
    log(f"consuming from list {QUEUE}")
    while True:
        item = client.blpop(QUEUE, timeout=5)
        if item:
            log(f"processing {item[1].decode()}")
            time.sleep(WORK_SECONDS)


def redis_produce():
    client = redis_client()
    client.rpush(QUEUE, *[f"job-{i + 1}" for i in range(COUNT)])
    log(f"pushed {COUNT} items to list {QUEUE}")


MODES = {
    "rabbitmq-consume": rabbitmq_consume,
    "rabbitmq-produce": rabbitmq_produce,
    "redis-consume": redis_consume,
    "redis-produce": redis_produce,
}

if __name__ == "__main__":
    if MODE not in MODES:
        sys.exit(f"MODE must be one of: {', '.join(MODES)}")
    MODES[MODE]()
