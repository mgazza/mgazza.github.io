---
title: "Using socat to backdoor via kubernetes"
date: 2021-01-22T09:02:12Z
description: Introduction to Sample Post
menu:
  sidebar:
    name: socat
    identifier: socat
    weight: 10
---

Sometimes when you're developing or debugging locally you need access to resources that are exposed to your cluster.

Typically, most organisations use VPN's to enable you to access these resources, but there's a much easier way.

## Socat.

The alpine/socat image is perfect for enabling backdoor access to private or internal services that are available to
your cluster without having to set up and manage VPN's.

How it works is pretty simple. We run a socat pod exposing a service that's viewable by the pod but not by us.

We then run a `kubectl port-forward` to expose the socat forward.

At this point we now have access to the private service locally.

```bash
export PORT=5432
export ADDR=postgres
export PODNAME=backdoor
kubectl run --restart=Never --image=alpine/socat ${PODNAME} -- -d -d tcp-listen:${PORT},fork,reuseaddr tcp-connect:${ADDR}:${PORT}
kubectl wait --for=condition=Ready pod/${PODNAME}
kubectl port-forward pod/${PODNAME} ${PORT}:${PORT}
```


### You don't need to do use socat
As most of you will probably be aware using socat to expose services like this is a bit overkill,
you can simply use ExternalName services instead and port-forward that.

```bash
export PORT=5432
export ADDR=postgres
export SERVICE_NAME=backdoor
cat <<EOF | kubeclt create -f -
kind: Service
apiVersion: v1
metadata:
  name: ${SERVICE_NAME}
spec:
  type: ExternalName
  externalName: ${ADDR}
EOF
kubectl port-forward service/${SERVICE_NAME} ${PORT}:${PORT}
```