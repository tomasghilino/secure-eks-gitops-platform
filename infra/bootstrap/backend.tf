terraform {
  backend "s3" {
    bucket = "segp-tfstate-6a72d03e8b67483fa434f7ec49"
    key    = "bootstrap/terraform.tfstate"
    region = "us-east-1"

    encrypt = true
    # without kms_key_id, encrypt = true writes with sse-s3 and skips the state key
    kms_key_id   = "alias/segp-tfstate"
    use_lockfile = true
  }
}
