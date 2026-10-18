# KEDA example worker. Built inside the cluster by devkit
# ("minikube image build"), so no registry is needed.
FROM python:3.13-alpine
RUN pip install --no-cache-dir pika==1.3.2 redis==5.2.1
WORKDIR /app
COPY worker.py .
USER 65534
ENTRYPOINT ["python", "-u", "worker.py"]
