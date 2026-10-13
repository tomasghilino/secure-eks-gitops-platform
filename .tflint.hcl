plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "aws_provider_missing_default_tags" {
  enabled = true
  tags    = ["Project", "ManagedBy"]
}
