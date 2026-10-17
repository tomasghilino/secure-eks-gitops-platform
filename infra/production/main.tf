data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "segp-tfstate-6a72d03e8b67483fa434f7ec49"
    key    = "shared/terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_caller_identity" "current" {}

# the sso role behind the current session, which becomes cluster admin
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# same module as staging, with its own network range so the two vpcs could be peered later;
# brought up only for the work that needs it, then destroyed
module "environment" {
  source = "../modules/environment"

  name                 = "segp-production"
  vpc_cidr             = "10.30.0.0/16"
  zone_ids             = ["use1-az1", "use1-az2"]
  flow_logs_bucket_arn = data.terraform_remote_state.shared.outputs.logs_bucket_arn

  kubernetes_version      = "1.35"
  admin_cidr              = var.admin_cidr
  admin_role_arn          = data.aws_iam_session_context.current.issuer_arn
  cluster_secrets_key_arn = data.terraform_remote_state.shared.outputs.cluster_secrets_key_arn
  api_repository_arn      = data.terraform_remote_state.shared.outputs.api_repository_arn

  # on-demand: a spot interruption here would take down prometheus, loki and half of the api at once;
  # on-demand node groups try the types in order and spot shortages don't apply, so one type is enough
  node_capacity_type  = "ON_DEMAND"
  node_instance_types = ["t3.large"]
}
