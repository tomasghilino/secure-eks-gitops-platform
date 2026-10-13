data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "signing_key" {
  #checkov:skip=CKV_AWS_109:key policy, where "*" means this key only (aws default statement)
  #checkov:skip=CKV_AWS_111:key policy, where "*" means this key only (aws default statement)
  #checkov:skip=CKV_AWS_356:key policy, where "*" means this key only (aws default statement)
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

# the private half never leaves kms: ci asks kms to sign image digests, and anyone holding
# the public key can verify them
resource "aws_kms_key" "signing" {
  description              = "cosign image signing"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  # losing this key means no image can be verified, so a deletion gets the longest window
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.signing_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "signing" {
  name          = "alias/segp-cosign"
  target_key_id = aws_kms_key.signing.key_id
}

data "aws_kms_public_key" "signing" {
  key_id = aws_kms_key.signing.arn
}
