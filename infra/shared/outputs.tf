output "api_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "signing_key_alias" {
  value = aws_kms_alias.signing.name
}

output "signing_public_key" {
  value = data.aws_kms_public_key.signing.public_key_pem
}

output "github_ci_role_arn" {
  value = aws_iam_role.github_ci.arn
}
