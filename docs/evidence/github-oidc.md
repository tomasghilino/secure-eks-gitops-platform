# CI talks to AWS without keys, and only from dev

GitHub Actions gets short-lived AWS credentials through OIDC. The IAM role trusts exactly one thing: a push to `dev` in this repository. Pull requests and other branches get nothing.

To test it, I opened a PR that loosened the trust to any branch (`StringLike repo:<this repo>:*`) and let the AWS job run on pull requests. It failed twice:

```text
terraform  failure   Check: CKV_SEGP_1 "Ensure web identity trust policies pin one exact subject"
aws        failure   Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

The first one is Checkov reading the code. The second is AWS refusing the PR's token, because the trust that's actually applied still only accepts `dev`.

`CKV_SEGP_1` is a rule I wrote. Checkov's built-in GitHub OIDC check never fired on my code: it only recognizes the provider when the ARN is written out by hand, and mine comes from a Terraform reference. It passed even with `sub = "*"`.

Two smaller surprises on the way. GitHub now puts the owner and repo IDs in the token's subject, so my first trust policy got denied until I switched to the new format. And with the role ARN in a repository variable, the job log printed the account ID, so the ARN became a secret.
