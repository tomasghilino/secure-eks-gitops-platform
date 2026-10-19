# Terraform gates in CI, and a pull request they stopped

Short version: every push and pull request now checks the Terraform code with four tools. To prove the gate can fail, I opened a pull request that loosens the public access block on the state bucket. Checkov failed it, and TFLint didn't notice, which is the point of running both.

## The job

```text
terraform
  format     terraform fmt -check -diff -recursive infra
  validate   terraform init -backend=false -lockfile=readonly && terraform validate   (each stack)
  tflint     tflint --init && tflint --recursive --chdir=infra                        (aws ruleset 0.49.0)
  checkov    checkov -d infra --framework terraform --skip-download                   (no network)
```

- No AWS access. The job never reads the state and has no credentials. `-backend=false` checks the code only.
- Strict lock file. `-lockfile=readonly` fails the job if the lock file lacks the Linux provider hashes, instead of quietly writing new ones.
- Pinned images. All three images are pinned by digest. None of them publishes a signature.
- TFLint token. TFLint gets the job's read-only `GITHUB_TOKEN` to download its AWS ruleset, because GitHub rate limits anonymous downloads from shared runners.

## Green on dev

```text
run 38442725399 on dev
  terraform  success  43s     Success! The configuration is valid.
                              Passed checks: 39, Failed checks: 0, Skipped checks: 6
```

## The unsafe change

Pull request #3 (draft), a single commit on a throwaway branch:

```diff
 resource "aws_s3_bucket_public_access_block" "state" {
   block_public_acls       = true
-  block_public_policy     = true
+  block_public_policy     = false
   ignore_public_acls      = true
-  restrict_public_buckets = true
+  restrict_public_buckets = false
 }
```

With those two off, a bucket policy granting `"Principal": "*"` would be accepted, and the Terraform state could be read by anyone on the internet.

```text
run 38443121772 on pull request #3
  terraform  failure      Passed checks: 36, Failed checks: 3, Skipped checks: 6
    CKV_AWS_56   Ensure S3 bucket has 'restrict_public_buckets' enabled
    CKV_AWS_54   Ensure S3 bucket has block public policy enabled
    CKV2_AWS_6   Ensure that S3 bucket has a Public Access block
  tflint        0 issues  (correctness only, security is not its job)
  every other job  success
```

## Limitation

Branch protection is not available for a private repository on the free plan. The red check warns, but GitHub would still let someone merge. Once the repository is public, a ruleset will make the `terraform` check required.
