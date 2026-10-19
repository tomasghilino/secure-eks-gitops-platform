# Promotion by pull request, a check that staging came first, and rollback by revert

Short version: production only changes through a pull request that I merge. `scripts/promote.sh` opens it with the exact tag and digest staging runs. A CI job (`promotion`) fails any pull request that sets a production image staging never got. At admission, Kyverno checks the signature, the SBOM and the provenance again. Rolling back means reverting the pull request.

## The promotion check failing on purpose

Draft PR #6 set production to `9f59013`, an image CI built before signing existed and that never went to staging:

```text
promotion   fail   6s
staging never got 9f59013a2c850448f20a20b3cd9114067d9a114e@sha256:f46ab08d..., so it can't go to production
##[error]Process completed with exit code 1.
```

Closed without merging; the branch was deleted. Had it been merged anyway, Kyverno would have denied the pods: `the api image is not signed with the ci key`. Two independent gates, one in Git and one in the cluster.

## A real promotion

```text
staging     chore: deploy 388ea79 to staging (direct commit, as for every staging deploy)
            staging pod: <account>.dkr.ecr.us-east-1.amazonaws.com/segp-api:388ea79c...@sha256:3fc1eead...
            health/ready 200 · POST /users 201 · GET /users 200

$ ./scripts/promote.sh
-  tag: "750de9aa1357afb77dc163ed924c115d0fc167df"
-  digest: "sha256:eec81819d13b5defbeb7165e8fa36acc933f4caa3b563a8a2047e1e14a5d4b44"
+  tag: "388ea79c227dcc6dbab79db546a0e18ea5bc94b6"
+  digest: "sha256:3fc1eeadaa0eb364f38166e24b83f79e579e54de8de7f17b2220a0e4e6a84646"
PR #7  chore: promote 388ea79 to production
checks: charts, deps, image, promotion, sast, secrets, terraform, test all pass
        promotion: "staging got 388ea79c...@sha256:3fc1eead... in bca9b24 on 2026-10-17"
merged by me (squash), Argo CD refreshed

rolled out 50 s after the refresh, one pod at a time:
  Scaled up replica set api-5fc84dffdb from 0 to 1
  pod/api-5fc84dffdb-hzpq9   Container started        (admitted: signature, sbom, provenance checked again)
  Scaled down replica set api-7fc6555b9 from 2 to 1
  Scaled up replica set api-5fc84dffdb from 1 to 2
  Scaled down replica set api-7fc6555b9 from 1 to 0
api-5fc84dffdb   2 ready   segp-api:388ea79c...@sha256:3fc1eeadaa0e...
api-7fc6555b9    0         segp-api:750de9aa...@sha256:eec81819d13b...   (kept: the rollback reuses it)
health/ready 200, the user created before the promotion is still there (rds)
```

## Rollback by revert

Pretend an alert fires right after the promotion. I clicked "Revert" on PR #7. GitHub opened PR #8 against dev, and I merged it after its checks passed:

```text
PR #8  Revert "chore: promote 388ea79 to production"   base=dev
       promotion: "staging got 750de9aa...@sha256:eec81819... in d9b8e89 on 2026-10-16"   (a rollback is to an image staging already ran, so it passes)

rolled back 62 s after the refresh:
  Scaled up replica set api-7fc6555b9 from 0 to 1        <- the replica set kept from before the promotion
  Scaled up replica set api-7fc6555b9 from 1 to 2
  Scaled down replica set api-5fc84dffdb from 2 to 1
  Scaled down replica set api-5fc84dffdb from 1 to 0
api-7fc6555b9    2 ready   segp-api:750de9aa...@sha256:eec81819d13b...
health/ready 200, data still there
```

The revert is a commit like any other. Git history shows who promoted, who rolled back and when, and Argo CD needed no manual command.

## What Kyverno asked ECR for (CloudTrail, production)

```text
segp-production-kyverno   GetAuthorizationToken    17   OK
segp-production-kyverno   BatchGetImage            17   OK
segp-production-kyverno   GetDownloadUrlForLayer   11   OK
segp-production-kyverno   ListImageReferrers        5   OK   (listing the signature and attestation referrers; allowed by BatchGetImage)
```
