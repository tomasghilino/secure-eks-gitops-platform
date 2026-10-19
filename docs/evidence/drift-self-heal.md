# Drift demo: a manual change in production undone in seconds

Short version: I changed production by hand, outside Git, the way someone might during a stressful incident. Argo CD noticed the cluster no longer matched Git and put it back within the same second.

Git says production runs two API pods. I scaled it to five:

```text
17:14:19 kubectl scale deployment api -n production --replicas=5
deployment.apps/api scaled
17:14:19 spec.replicas=5  argo=OutOfSync
17:14:21 spec.replicas=2  argo=Synced
```

Argo CD records that the fix was automatic, and that it re-applied only the resource that drifted, at the same Git commit:

```text
initiatedBy: {"automated":true}
Succeeded  successfully synced (all tasks run)

ResourceUpdated      Updated health status: Healthy -> Progressing
OperationCompleted   Partial sync operation to dcf8f893600d9eeaaf51bfe1dbe60181572bb6f3 succeeded
ResourceUpdated      Updated sync status: OutOfSync -> Synced
ResourceUpdated      Updated health status: Progressing -> Healthy
```

The three extra pods were created and removed right away, and the two original pods were never touched:

```text
api-688c8f9869-5t5zr   1/1   Running       0   6m45s
api-688c8f9869-txfxw   1/1   Running       0   6m45s
api-688c8f9869-hpk89   1/1   Terminating   0   9s
api-688c8f9869-v8d2s   1/1   Terminating   0   9s
api-688c8f9869-xq2rd   1/1   Terminating   0   9s
```

The lesson: with self-heal on, the only lasting way to change production is a commit. A quick `kubectl` fix during an incident gets reverted, so the fix has to go through Git, where it is reviewed and recorded.
