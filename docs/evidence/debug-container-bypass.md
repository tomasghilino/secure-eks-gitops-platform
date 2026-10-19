# A hole in the image rules: kubectl debug

While reviewing who can do what in the cluster, I noticed the image policies only looked at pods being created. `kubectl debug` adds a container to a pod that's already running, through a different API path the policies never saw. So busybox, which they'd normally reject, ran inside a staging API pod:

```text
kubectl debug <api pod> --image=busybox:1.37@sha256:... --profile=restricted   -> accepted, image pulled
the same with runAsUser 65534                                                  -> running inside the api pod
  uid=65534(nobody)
```

My first fix added that path to the existing policies, and CI went quiet in a bad way. The Kyverno CLI evaluated zero rules instead of twelve and still passed, because matching that path turned off the rules Kyverno generates for Deployments, which is exactly what CI checks. I moved the debug check into its own policy and made CI fail whenever Kyverno evaluates nothing:

```text
debug with busybox     denied by restrict-debug-container-images
kyverno-cli in ci      pass: 12 per environment again
```

The same review emptied Argo CD's catch-all project, so nothing can be deployed through it. It also moved Kyverno to three replicas: its policies fail closed, so with a single replica down, no new pod could start.
