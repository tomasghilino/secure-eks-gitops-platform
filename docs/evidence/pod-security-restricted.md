# Pod Security "restricted" on the environment namespaces

Short version: the staging and production namespaces now reject any pod that could run as root, escalate privileges or keep Linux capabilities. Before turning it on, I checked that every pod already running would pass, so nothing broke.

## Checking before enforcing

A server-side dry run of the label shows which running pods would violate the level, without applying anything:

```text
$ kubectl label --dry-run=server --overwrite namespace staging pod-security.kubernetes.io/enforce=restricted
namespace/staging labeled (server dry run)          <- no warnings: everything complies
```

The same check against `kube-system`, where system pods legitimately need privileges, shows what a failure looks like:

```text
Warning: existing pods in namespace "kube-system" violate the new PodSecurity enforce level "restricted:latest"
Warning: kube-proxy-7tvrq (and 2 other pods): host namespaces, privileged, allowPrivilegeEscalation != false, ...
```

## The namespaces live in Git now

A new `baseline` chart renders each environment namespace with its Pod Security labels. Argo CD manages it under its own `baseline` project, separate from the apps' project, so app charts can't create namespaces or grant themselves permissions.

```text
pod-security.kubernetes.io/enforce=restricted
pod-security.kubernetes.io/enforce-version=v1.35
pod-security.kubernetes.io/warn=restricted
pod-security.kubernetes.io/warn-version=latest
pod-security.kubernetes.io/audit=restricted
pod-security.kubernetes.io/audit-version=latest
```

Enforcement is pinned to the rules of Kubernetes 1.35, so a cluster upgrade can't start rejecting pods by surprise. Warnings and audit use `latest`, so the stricter rules show up early. The namespace also carries `Prune=false,Delete=false` for Argo CD: deleting a namespace deletes everything in it, including the database volume.

After the push, Argo CD labelled both namespaces in 11 seconds.

## The demo

```text
$ kubectl run pwn --image=busybox:1.37 --namespace staging --privileged --dry-run=server -- sleep 3600
Error from server (Forbidden): pods "pwn" is forbidden: violates PodSecurity "restricted:v1.35":
  privileged (container "pwn" must not set securityContext.privileged=true),
  allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile

$ kubectl run test --image=busybox:1.37 --namespace production --dry-run=server -- sleep 3600
Error from server (Forbidden): pods "test" is forbidden: violates PodSecurity "restricted:v1.35":
  allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile

$ kubectl run pwn --image=busybox:1.37 --namespace default --privileged --dry-run=server -- sleep 3600
pod/pwn created (server dry run)      <- control: a namespace without the labels accepts it
```

Even a pod that isn't privileged at all gets rejected if it doesn't explicitly opt out of root, privilege escalation and capabilities.

To show the real workloads still pass, I deleted the staging API pod. Its replacement went through the same admission check and was Running and Ready two seconds later.
