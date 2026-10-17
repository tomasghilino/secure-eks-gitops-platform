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

# created at the start of a working session and destroyed at the end, so it costs nothing in between
module "environment" {
  source = "../modules/environment"

  name                 = "segp-staging"
  vpc_cidr             = "10.20.0.0/16"
  zone_ids             = ["use1-az1", "use1-az2"]
  flow_logs_bucket_arn = data.terraform_remote_state.shared.outputs.logs_bucket_arn

  kubernetes_version      = "1.35"
  admin_cidr              = var.admin_cidr
  admin_role_arn          = data.aws_iam_session_context.current.issuer_arn
  cluster_secrets_key_arn = data.terraform_remote_state.shared.outputs.cluster_secrets_key_arn
  api_repository_arn      = data.terraform_remote_state.shared.outputs.api_repository_arn

  # staging can lose a node to a spot interruption without hurting anyone
  node_capacity_type  = "SPOT"
  node_instance_types = ["t3.large", "t3a.large", "m5.large", "m6i.large", "m7i-flex.large"]
}
