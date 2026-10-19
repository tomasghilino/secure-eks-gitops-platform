# The CI role can push and sign one image repository, and nothing else

Short version: the GitHub Actions role could log in to AWS but had no permissions yet. I gave it exactly what publishing an image needs: push to the `segp-api` repository and sign with the cosign key. Then I asked the IAM policy simulator what the role can and can't do, without running any of those actions for real.

## The policy (infra/shared/github.tf)

```text
+ aws_iam_role_policy.github_ci   "publish-api-image" on role segp-github-ci
    EcrLogin        ecr:GetAuthorizationToken                       *
    PushApiImages   8 ECR actions (upload layers, PutImage, read)   repository/segp-api
    SignImages      kms:Sign, kms:GetPublicKey, kms:DescribeKey     key/<signing key>
Plan: 1 to add, 0 to change, 0 to destroy.
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

- The login token can't be scoped. `GetAuthorizationToken` only works with `*`, but on its own it can't push anything.
- Read access is on purpose. cosign and Trivy need to read the pushed image back. Listing the signatures stored next to an image also needs `ecr:BatchGetImage`.
- Inline policy. It belongs to this role only.

Checkov ran 13 rules against the new policy and all passed: no admin, no `*` on actions that can be scoped, no privilege escalation, no data exfiltration, no unconstrained write access. Overall: `Passed checks: 83, Failed checks: 0, Skipped checks: 10`.

## What the simulator says

```text
$ aws iam simulate-principal-policy --policy-source-arn <ci role> --action-names ... --resource-arns ...

ecr:GetAuthorizationToken        *                            allowed
ecr:PutImage                     repo segp-api                allowed
ecr:BatchGetImage                repo segp-api                allowed
ecr:BatchDeleteImage             repo segp-api                implicitDeny
ecr:PutLifecyclePolicy           repo segp-api                implicitDeny
ecr:SetRepositoryPolicy          repo segp-api                implicitDeny
ecr:PutImage                     repo other-team-app          implicitDeny
ecr:BatchGetImage                repo other-team-app          implicitDeny
kms:Sign                         signing key                  allowed
kms:GetPublicKey                 signing key                  allowed
kms:ScheduleKeyDeletion          signing key                  implicitDeny
kms:DisableKey                   signing key                  implicitDeny
kms:PutKeyPolicy                 signing key                  implicitDeny
kms:Sign                         state key                    implicitDeny
kms:Decrypt                      state key                    implicitDeny
s3:GetObject                     state bucket                 implicitDeny
s3:PutObject                     state bucket                 implicitDeny
iam:PassRole                     *                            implicitDeny
iam:CreateRole                   *                            implicitDeny
```

`implicitDeny` means no statement allows it, so AWS refuses by default. If the CI is compromised, the attacker can push and sign `segp-api` images. That is the risk I accept, and admission control limits it: the cluster only accepts images signed with this key. The attacker can't delete images, read or change the Terraform state, disable the key, or create new roles.

The simulator only evaluates identity policies. Both KMS key policies delegate to IAM, so for these keys the answer matches what AWS would really decide.
