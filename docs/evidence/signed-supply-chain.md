# A signed supply chain from commit to registry

Short version: a push to dev now ends with an image in ECR that has been scanned before it was pushed, is identified by its digest, and carries three signed documents: a signature, an SBOM and a provenance record. The CI checks all three against the public key in Git, the same key the cluster checks before any pod starts ([signed-images-at-admission.md](signed-images-at-admission.md)).

```text
[test][secrets][sast][deps][charts] -> [image] ---------+
                         [terraform] -------------------+-> [publish] -> ECR segp-api@sha256:...
   no aws credentials anywhere above                   |     ├── signature            (cosign, KMS key)
                                    image.tar artifact -+     ├── SBOM (CycloneDX)     (attestation)
                                                              └── provenance (SLSA v1) (attestation)
```

Last run (commit 4557514): every job green, image 86 s, publish 67 s (push 25 s, SBOM 8 s, sign and attest 12 s, verify 9 s). ECR holds 5 images and 7 cosign artifacts. `AROA` appears 0 times in the log.

## Commits

```text
b581aab feat: let ci push and sign api images                     (iam policy, checked with the simulator)
9f59013 ci: publish the scanned api image to ecr                  (separate publish job, push by digest)
b03db18 fix: mask the ci role id, which encodes the aws account id
06d508a ci: sign api images with the kms key
55cdb4c ci: give the real reason for signing without rekor
1366db7 ci: attest the sbom and provenance of api images
4557514 feat: expire old api images in ecr
```

## What I checked, and what I found

- The CI role can only push and sign this one repository. The IAM simulator showed `implicitDeny` for deleting images, the lifecycle policy, other repositories, the state bucket, the state key and IAM. See [ci-role-permissions.md](ci-role-permissions.md).
- The scanned image is the published image. The build job saves the tarball, and the publish job pushes that exact file; the artifact digest is checked on download. Re-running only the publish job pushed the same digest, and ECR accepted it.
- Finding: the AWS login action leaks the account ID in disguise. It prints the role ID (`AROA...`), and AWS IDs encode the account ID. I decoded it locally to confirm. Fixed by storing the ID as a secret, so GitHub masks it, plus a step that fails if the secret doesn't match the role.
- Signatures sit next to the image, not in a tag. Cosign 3 stores them as OCI referrers, so immutable tags are fine. There's no Rekor entry; CloudTrail records every `kms:Sign` with the role and run.
- Corrected myself. The signed statement only contains the digest, so my comment that Rekor would record the account ID was wrong.
- Finding: cosign's output is misleading. It says the transparency log was "verified offline" even when there are zero log entries.
- The SBOM now names the real image, not `image.tar`.
- Finding: the Node.js runtime is missing from the SBOM. Distroless installs it from a tarball, so neither the SBOM nor the Trivy scan would flag a Node security release.
- The provenance is honest about its level. It's SLSA Build L1 with a signature, written by my own workflow, not by GitHub.
- Lifecycle rules never select signatures or attestations, not even an `untagged` or `any` rule. I tested this with the preview before applying anything.
- Every check that should fail does.
  - Unsigned image: exit 10.
  - Another key: exit 1.
  - Missing or wrong attestation type: exit 1.
  - Another key on an attestation: exit 1.

## Once the repository is public

- The old run logs that contain the role ID get deleted first, together with the local `gh` log cache.
- GitHub's native attestations or the SLSA generator (`slsa-github-generator`) would raise the provenance to L2 or L3, and keyless signing with Rekor becomes an option.
