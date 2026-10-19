# Staging asks for production's password, and AWS says no

External Secrets copies the database passwords from Secrets Manager into the cluster. In staging it runs with its own IAM role, which can read the two staging secrets and nothing else.

I created an ExternalSecret in staging that asked for production's API password, the way someone with write access to the staging namespace might try it:

```text
db-admin          SecretSynced       True
db-credentials    SecretSynced       True
steal-production  SecretSyncedError  False
  event UpdateFailed: ... GetSecretValue, https response error StatusCode: 400, ... api error AccessDeniedException

$ kubectl -n staging get secret steal-production
Error from server (NotFound): secrets "steal-production" not found
```

No Secret was created, and the real ones kept working. CloudTrail logged the denied calls under the External Secrets role. It doesn't say which secret was requested when a call is denied, though, so you have to search by role and error code.

The role is limited twice: its policy names the two staging secrets, and its trust only accepts that one service account in the staging cluster.
