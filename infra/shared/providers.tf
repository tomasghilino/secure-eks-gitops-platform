provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "secure-eks-gitops-platform"
      Stack     = "shared"
      ManagedBy = "terraform"
    }
  }
}
