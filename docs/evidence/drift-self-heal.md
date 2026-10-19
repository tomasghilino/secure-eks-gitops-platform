# A manual change in production, undone in two seconds

Git says production runs two API pods. I scaled it to five by hand, the kind of quick fix someone might try during an incident:

```text
17:14:19 kubectl scale deployment api -n production --replicas=5
17:14:19 spec.replicas=5  argo=OutOfSync
17:14:21 spec.replicas=2  argo=Synced
```

Argo CD noticed the cluster no longer matched Git and put it back. The three extra pods were removed right away, and the two original ones were never touched.

That's the point of self-heal, and also the catch: in the middle of an incident, a kubectl fix won't stick. The fix has to be a commit, which means someone reviews it and it stays on record.
