# aws checks the token signature against github's published keys, so no thumbprint is pinned here
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_ci_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # only pushes to dev: pull requests, other branches and other repositories get a different subject
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/dev"]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name                 = "segp-github-ci"
  assume_role_policy   = data.aws_iam_policy_document.github_ci_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_ci" {
  # the login token itself cannot be limited to one repository
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # read is needed too: cosign and trivy fetch the pushed image by digest
  statement {
    sid = "PushApiImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.api.arn]
  }

  statement {
    sid       = "SignImages"
    actions   = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
    resources = [aws_kms_key.signing.arn]
  }
}

resource "aws_iam_role_policy" "github_ci" {
  name   = "publish-api-image"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci.json
}
