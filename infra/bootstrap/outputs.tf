output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "state_kms_key_alias" {
  value = aws_kms_alias.state.name
}
