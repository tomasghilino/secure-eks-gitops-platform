# registry level because aws is deprecating the per-repository scan on push setting
resource "aws_ecr_registry_scanning_configuration" "main" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

# no lifecycle policy yet: cosign stores signatures as untagged artifacts, so an untagged expiry rule
# is only added once a signed image can be checked against the lifecycle preview
resource "aws_ecr_repository" "api" {
  #checkov:skip=CKV_AWS_163:scan on push is configured for the whole registry above
  name                 = "segp-api"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
  }
}
