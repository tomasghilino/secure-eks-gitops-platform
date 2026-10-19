# A namespace asks for production secrets, and AWS says no

Short version: External Secrets runs with its own Pod Identity role, which may read only `segp-staging/database/admin` and `segp-staging/database/api`. I created an ExternalSecret in staging that asks for `segp-production/database/api`, as an attacker with write access to the staging namespace might. AWS denied it, no Secret was created, and both the cluster and CloudTrail show who tried.

```text
$ kubectl -n staging get externalsecret
db-admin          SecretSynced       True
db-credentials    SecretSynced       True
steal-production  SecretSyncedError  False

event UpdateFailed: error processing spec.dataFrom[0].extract, err: operation error Secrets Manager:
GetSecretValue, https response error StatusCode: 400, ... api error AccessDeniedException:
User: <external secrets role session> ...

$ kubectl -n staging get secret steal-production
Error from server (NotFound): secrets "steal-production" not found

$ aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue
20:42:35Z  segp-staging-external-secrets -> segp-staging/database/api   OK
20:44:13Z  segp-staging-external-secrets -> (no parameters)            AccessDenied
20:44:13Z  ...                                                         AccessDenied (retries with backoff)
```

- The real secrets keep working. A failing ExternalSecret doesn't touch the Secrets that already exist.
- CloudTrail doesn't record which secret was asked for. It leaves out the parameters of denied calls, so you find the attempt by role and error code.
- The role is limited twice. Its permissions name the two staging secrets by ARN. Its trust policy accepts only the `external-secrets` service account in the `external-secrets` namespace of `segp-staging`, through Pod Identity session tags.
