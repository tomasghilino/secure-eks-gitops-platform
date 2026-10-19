# GitHub Actions logs in to AWS with OIDC, and only from dev

Short version: CI now gets short-lived AWS credentials from an IAM role that trusts exactly one subject: pushes to `dev` in this repository. No access key is stored anywhere. On the way I found three things: the trust policy had to use GitHub's new immutable subject, the role ARN leaked the account ID into a CI log, and Checkov's built-in GitHub OIDC rule couldn't catch a wildcard in my code. I fixed the first two and wrote my own rule for the third.

## What Terraform created (infra/shared/github.tf)

```text
aws_iam_openid_connect_provider.github   token.actions.githubusercontent.com, audience sts.amazonaws.com, no thumbprint
aws_iam_role.github_ci                   segp-github-ci, 1 hour sessions, no permissions yet (ECR push and kms:Sign came later)
  trust: StringEquals aud = sts.amazonaws.com
         StringEquals sub = repo:tomasghilino@<owner id>/secure-eks-gitops-platform@<repo id>:ref:refs/heads/dev
```

## First run: denied, because of the subject format

```text
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity

$ gh api repos/<owner>/<repo>/actions/oidc/customization/sub
{"use_default":true,"use_immutable_subject":true,"sub_claim_prefix":"repo:tomasghilino@<owner id>/secure-eks-gitops-platform@<repo id>"}
```

Since July 2026, GitHub puts the owner and repository IDs into the subject of every new repository. If someone deletes a repository and another person registers the same name, the IDs differ, so the trust doesn't carry over. My policy used the old name-only format. AWS refused it, which is the behavior I want from an exact match. I updated the subject and the next run went through.

## The account ID in a log

GitHub prints every step input. With the role ARN stored as a repository variable, the log showed `role-to-assume: arn:aws:iam::<account id>:role/...`. I moved the ARN to a repository secret, deleted that run's logs (`DELETE /actions/runs/{id}/logs`, then 404) and deleted the variable. Now the log shows:

```text
role-to-assume: *
Authenticated as assumedRoleId <role id>:ci-38470699900
segp-github-ci/ci-38470699900
```

The session name carries the run number, so CloudTrail shows which CI run used the role.

## Checkov's rule couldn't fail on my code

CKV_AWS_358 decides that a statement is about GitHub by looking for `oidc-provider/token.actions.githubusercontent.com` in the principal text. My principal is a Terraform reference, so the rule passed even with `sub = "*"`:

| Unsafe trust | CKV_AWS_358 | CKV_SEGP_1 (mine) |
|---|---|---|
| `StringLike repo:*` | PASSED | FAILED |
| `StringLike repo:<this repo>:*` | PASSED | FAILED |
| `StringEquals` with a `*` inside | PASSED | FAILED |
| no `sub` condition | PASSED | FAILED |

`checkov/web_identity_subject.py` checks every `sts:AssumeRoleWithWebIdentity` statement and requires `StringEquals` on `:sub` with no wildcards. CI loads it with `--external-checks-dir checkov`.

Two more things I found in CKV_AWS_358 while testing with a literal ARN:
- Only the first statement counts. If another statement comes first, the rule passes without reading the GitHub one, even with `sub = "*"`.
- The new format fails. A correct trust that uses the immutable subject is marked FAILED, because the rule expects `owner/repo`.

## The demo: a pull request that tries to widen the trust

Pull request #4 changed the subject to `StringLike repo:<this repo>:*` (any branch or pull request) and let the `aws` job run on pull requests:

```text
run 38471042730 on pull request #4
  terraform  failure   Check: CKV_SEGP_1 "Ensure web identity trust policies pin one exact subject"
                       FAILED for resource: aws_iam_policy_document.github_ci_trust
                       Passed checks: 69, Failed checks: 1, Skipped checks: 10
  aws        failure   Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
  every other job  success
```

There are two layers here:
- The code gate. Checkov fails the policy change before anyone applies it.
- AWS itself. It refuses the pull request's token, because the trust that is actually applied only accepts pushes to `dev`. Editing the workflow in a pull request doesn't get AWS credentials.

CloudTrail recorded each attempt with its subject:

```text
2026-10-13T18:27:13-03:00  OK            ...secure-eks-gitops-platform@<repo id>:ref:refs/heads/dev
2026-10-13T18:29:57-03:00  AccessDenied  ...secure-eks-gitops-platform@<repo id>:pull_request   (x12, the action retries)
```

I closed the pull request without merging and deleted its branch.
