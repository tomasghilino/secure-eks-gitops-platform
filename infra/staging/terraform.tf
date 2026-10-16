terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
    # 3.7 added the ephemeral random_password, which keeps generated passwords out of the state
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
