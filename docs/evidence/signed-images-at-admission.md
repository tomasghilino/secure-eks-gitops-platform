# Only signed images run: Kyverno checks the signature, the SBOM and the provenance at admission

Short version: in staging and production, Kyverno now rejects any pod whose API image isn't signed with the CI's KMS key. The image also needs the CycloneDX SBOM and the SLSA provenance that CI attached, both signed with that key, and the provenance must say the image was built from this repository's dev branch. A second policy allows only that image, plus one listed image by exact digest, so nobody can dodge the check by running something else.

## The chain at admission

```text
1. restrict-image-sources (validating)   only segp-api:<40-hex commit>@sha256:<digest>, from no registry or any ecr,
                                          or an image listed in the baseline values (the postgres setup image)
2. use-ecr-registry (mutating)           completes segp-api:... with our registry, read from a configmap
3. verify-api-image (image validating)   every segp-api image from any ecr: signature + sbom + provenance with cosign.pub,
                                          provenance built from refs/heads/dev of this repository
```

Kyverno reads the registry with its own Pod Identity role. That role is read-only (`BatchGetImage`, `GetDownloadUrlForLayer`) and only covers the `segp-api` repository:

```text
kyverno-admission-controller env:  AWS_CONTAINER_CREDENTIALS_FULL_URI, AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
policies in production:            verify-api-image READY true ("Background scanning disabled; reporting permissions not required")
                                   restrict-image-sources, use-ecr-registry, disallow-latest-tag, ... READY true
```

## The failure demos (production, `kubectl apply --dry-run=server`, same compliant pod, only the image changes)

```text
signed-with-sbom      segp-api:750de9aa...@sha256:eec81819...   pod/signed-with-sbom created (server dry run)
never-signed          segp-api:9f59013a...@sha256:f46ab08d...   denied: the api image is not signed with the ci key
signed-without-sbom   segp-api:06d508a2...@sha256:fa2084cd...   denied: the api image has no sbom signed with the ci key
docker-hub            docker.io/library/nginx:1.29@sha256:...    denied (restrict-image-sources): only the api image pinned
                                                                 to a commit and a digest, or an image listed in the
                                                                 baseline values, may run here
someone-elses-ecr     111122223333.dkr.ecr.../segp-api:750de9aa...@sha256:eec81819...
                                                                 denied: kyverno's role can't read that registry (DENIED),
                                                                 and the policy fails closed
```

- The first two images are real images from our own ECR. CI built them before signing existed and before attestations existed. Same repository, same CI, still rejected.
- The copy in someone else's account is the bypass the allowlist leaves open on purpose. The allowlist accepts the API image from any ECR. The signature check closes that gap: nobody else can sign with our KMS key.

## Finding: my first policy rejected the good image too

The first dry run in production, minutes before the API's wave, rejected the signed image:

```text
denied: Policy verify-api-image error: failed to evaluate policy: no such key: buildDefinition
```

The signature and SBOM checks had passed; the provenance rule failed. I copied the policy into a throwaway namespace with a rule that prints the payload's keys:

```text
keys: _type,subject,predicateType,predicate
```

`extractPayload()` returns the whole in-toto statement, not just the predicate, so the path is `.predicate.buildDefinition...`. Fixed in one commit, tested in the throwaway namespace first (`pod/probe created (server dry run)`), then pushed. The API's migration job had been rejected twice in the meantime. The Job retried on its own, and the API came up with no manual step:

```text
job/api-migrate   FailedCreate ... denied ... no such key: buildDefinition     (before the fix)
job.batch/api-migrate   Complete 1/1
pod/api-...   1/1 Running   <account>.dkr.ecr.us-east-1.amazonaws.com/segp-api:750de9aa...@sha256:eec81819...   x2
```
