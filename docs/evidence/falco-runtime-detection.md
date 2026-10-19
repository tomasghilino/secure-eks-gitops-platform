# Falco: watching what running containers do

Short version: Kyverno decides which pods may start. Once a signed image is running, though, nothing watched what happened inside it. Now Falco runs on every node, watches the containers' system calls through the modern eBPF probe, and reports matches of its rules two ways: to Loki (the full detail) and to Prometheus (a counter that alerts). I played the attacker in a throwaway pod. Falco reported every step within 2 seconds, and Alertmanager had both alerts 38 seconds after the attack started.

## How it is installed

```text
chart falcosecurity/falco 9.2.0 (falco 0.45.0, released 4 weeks earlier), Argo CD app in its own AppProject (runtime-security)
image docker.io/falcosecurity/falco:0.45.0@sha256:788f1129...
  cosign verify: identity https://github.com/falcosecurity/falco/.github/workflows/reusable_publish_docker.yaml@refs/tags/0.45.0
  the same check with tag 0.44.1 in the identity: FAILED
driver modern_ebpf, leastPrivileged: capabilities BPF, PERFMON, SYS_RESOURCE, SYS_PTRACE instead of privileged: true
falcoctl off: the image already ships the 25 stable rules and the container plugin (libcontainer.so), so nothing
  unpinned is downloaded at startup
namespace falco: pod security "privileged" (host paths for /proc, /etc and the container runtime socket)
```

## Finding 1: the textbook alert would have missed the first attack

Falco's counter `falcosecurity_falco_rules_matches_total` only appears when a rule matches for the first time, and it appears already at 1. `increase()` sees 0 there, so an alert built only on `increase()` stays silent on the first match. The promtool unit tests showed it:

```text
increase() only:              FAILED  a warning rule matches for the first time   (got: [])
increase() or new series:     FAILED  the same  ("or" keeps the left side's 0 and drops the new series)
each half filtered "> 0":     SUCCESS (4 tests: first match, repeated match, critical vs warning, notice stays quiet)
```

In the cluster, before any attack, only one rule had a series. Its counter had appeared on its first match.

## Finding 2: Falco was noisy out of the box

Right after install, before any attack: 54 matches of "Contact K8S API Server From Container". Every one came from argo cd's application controller (50), kyverno (2) and the monitoring stack's webhook jobs (2), which talk to the API by design. The tuning (`customRules` in falco/values.yaml):

- the default rule ignores the platform namespaces (argocd, kyverno, external-secrets, monitoring, monitoring-agents);
- a new rule, "Environment pod contacts the Kubernetes API", raises a WARNING for the same connection from staging or production. The api runs without a service account token, so it has no reason to reach the API.

`falco -V` validated both rule files before the commit.

## The attack (throwaway namespace falco-demo, busybox pod as root)

```text
attack starts 18:23:19 UTC
18:23:21 WARNING | Read sensitive file untrusted         | pod attacker | cmd cat /etc/shadow                              | user root
18:23:21 WARNING | Find AWS Credentials                  | pod attacker | cmd grep -rs aws_secret_access_key /etc /root /home | user root
18:23:21 WARNING | Read sensitive file untrusted         | pod attacker | cmd grep -rs aws_secret_access_key ...        (grep read /etc/shadow too)
18:23:21 NOTICE  | Contact K8S API Server From Container | pod attacker | cmd wget ... https://kubernetes.default.svc

alertmanager 18:23:57   FalcoWarningEvent | Falco: Read sensitive file untrusted | active
                        FalcoWarningEvent | Falco: Find AWS Credentials         | active
```

Both were first matches, which is exactly the case finding 1 fixed. The alert's description gives the query to run next, and it returns the full event:

```text
loki {k8s_namespace_name="falco"} |= "Find AWS Credentials"
  Find AWS Credentials | Warning | falco-demo attacker | grep -rs aws_secret_access_key /etc /root /home | docker.io/library/busybox
```

## From inside a staging pod

A busybox debug container injected into an API pod in staging (see [admission-and-rbac-review.md](admission-and-rbac-review.md)) ran `wget https://kubernetes.default.svc`:

```text
wget: download timed out
```

The API pod's network policy only allows the database, the trace collector and DNS, so the connection never completed. Falco's API rule only matches completed connections, so it stayed silent. The network policy is the first layer. The Falco rule is the backup for the day a policy is missing or not enforced, as happened on EKS before the VPC CNI's network policy support was switched on ([platform-on-eks.md](platform-on-eks.md)).
