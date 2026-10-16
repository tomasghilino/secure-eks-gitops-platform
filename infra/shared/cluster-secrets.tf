# envelope encryption for kubernetes secrets in every cluster; kept between sessions, so destroying
# a cluster doesn't leave another key pending deletion each time
resource "aws_kms_key" "cluster_secrets" {
  description             = "eks secrets encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.account_managed_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "cluster_secrets" {
  name          = "alias/segp-eks-secrets"
  target_key_id = aws_kms_key.cluster_secrets.key_id
}
