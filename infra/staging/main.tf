data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "segp-tfstate-6a72d03e8b67483fa434f7ec49"
    key    = "shared/terraform.tfstate"
    region = "us-east-1"
  }
}

# created at the start of a working session and destroyed at the end, so it costs nothing in between
module "environment" {
  source = "../modules/environment"

  name                 = "segp-staging"
  vpc_cidr             = "10.20.0.0/16"
  zone_ids             = ["use1-az1", "use1-az2"]
  flow_logs_bucket_arn = data.terraform_remote_state.shared.outputs.logs_bucket_arn
}
