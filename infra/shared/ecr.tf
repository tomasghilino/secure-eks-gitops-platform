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

resource "aws_ecr_repository" "api" { # nosemgrep: terraform.lang.security.ecr-image-scan-on-push.ecr-image-scan-on-push
  #checkov:skip=CKV_AWS_163:scan on push is configured for the whole registry above
  name                 = "segp-api"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
  }
}

# checked with the lifecycle preview on signed images: no rule selects signatures or attestations,
# not even an untagged or any rule; ecr deletes them within 24 hours after their image
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "ci always tags, so an untagged image is a leftover"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        # production may run an older image than staging, so keep enough commits to cover it
        rulePriority = 2
        description  = "keep the 50 newest commit images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 50
        }
        action = { type = "expire" }
      },
    ]
  })
}
