# NetworkPolicies: default deny, then only what the app needs

Short version: before this change any pod could reach any other pod in the cluster, including the production database, Argo CD and the Kubernetes API. Now every environment namespace denies all traffic by default. The platform allows DNS, and each app chart opens exactly its own dependencies. A pod with no business in the namespace reaches nothing, and even a compromised API can only reach its own database.

## Before: a stray pod in staging could reach everything

I started a plain busybox pod (`intruder`) in staging, compliant with Pod Security so it was admitted:

```text
postgres (staging) :5432                         OPEN
api (staging) :80                                OPEN
postgres.production :5432                        OPEN
argocd-server.argocd :443                        OPEN
kubernetes API (kubernetes.default) :443         OPEN
```

## The rules

The platform (`charts/baseline`, in every environment namespace) owns these:

- `default-deny`: no ingress or egress for any pod.
- `allow-dns`: every pod may query cluster DNS on port 53.

Each app chart owns its own:

- `api`: ingress on its HTTP port from anyone, egress only to the database on 5432.
- `api-migrate`: egress only to the database on 5432. It's a pre-sync hook like the migration itself, otherwise the migration would run before its own permission existed and the deploy would never finish.
- `postgres`: ingress on 5432 only from the API and the migration pods.

Which peers the API may reach comes from values. On kind it's the Postgres pods, and on EKS it will become the RDS subnets without touching the templates.

## After: the stray pod reaches nothing

```text
postgres (staging) :5432                         blocked
api (staging) :80                                blocked
postgres.production :5432                        blocked
argocd-server.argocd :443                        blocked
kubernetes API (kubernetes.default) :443         blocked
DNS lookup of postgres                           works
```

Even the API is unreachable for it. The API accepts traffic from anyone, but the intruder isn't allowed to send any.

## From inside the API pod: only its own database

I attached a temporary debug container to the staging API pod. It shares the pod's network, so it shows what an attacker who took over the API could reach. The first attempt was rejected, because busybox runs as root and the pod requires non-root, so I ran it as user 65534.

```text
postgres:5432                                 OPEN
postgres.production.svc.cluster.local:5432    blocked
kubernetes.default.svc.cluster.local:443      blocked
argocd-server.argocd.svc.cluster.local:443    blocked
1.1.1.1:443                                   blocked
```

## The app still works

```text
staging    migrate job: Complete (ran after the policies existed)
production migrate job: Complete
staging    /health/ready={"status":"ok"}  POST /users=201
production /health/ready={"status":"ok"}  POST /users=201
```

kind enforces NetworkPolicies out of the box since v0.24 (kube-network-policies). On EKS the VPC CNI enforces the same objects.
