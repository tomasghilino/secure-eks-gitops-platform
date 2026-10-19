# Promoting to production, and rolling back

Production only changes through a pull request. `scripts/promote.sh` copies the exact tag and digest that staging runs into the production values and opens the PR, and merging it is the approval.

First I tried to cheat. A draft PR pointed production at an image that never went to staging, and the promotion check in CI caught it:

```text
promotion   fail
staging never got 9f59013a...@sha256:f46ab08d..., so it can't go to production
```

Even if I had merged it, Kyverno would have refused the pods, because that image was never signed. So there are two separate checks, one in Git and one in the cluster.

Then a real one. A PR promoted `388ea79`, and Argo CD rolled production one pod at a time in about 50 seconds. To roll back, I clicked Revert on that PR and merged the one GitHub opened. Production was back on the previous image 62 seconds later, reusing the old ReplicaSet that Kubernetes had kept around:

```text
Scaled up replica set api-7fc6555b9 from 0 to 1        <- the one from before the promotion
Scaled up replica set api-7fc6555b9 from 1 to 2
Scaled down replica set api-5fc84dffdb from 2 to 1
Scaled down replica set api-5fc84dffdb from 1 to 0
api-7fc6555b9    2 ready   segp-api:750de9aa...@sha256:eec81819d13b...
```

No kubectl and no manual steps, and the Git history shows who promoted, who rolled back and when.
