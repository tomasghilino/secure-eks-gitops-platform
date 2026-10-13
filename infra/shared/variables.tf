variable "region" {
  type    = string
  default = "us-east-1"
}

# github's immutable subject format puts the owner and repository ids next to their names, so a
# repository deleted and recreated under the same name by someone else does not inherit this trust
variable "github_repository" {
  type    = string
  default = "tomasghilino@86894891/secure-eks-gitops-platform@1409115401"
}
