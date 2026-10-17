variable "name" {
  description = "prefix for every resource, such as segp-staging"
  type        = string
}

variable "vpc_cidr" {
  type = string
}

# zone ids, not names: us-east-1a is a different zone in every account, use1-az1 is the same everywhere
variable "zone_ids" {
  description = "two or more zones; eks rejects some, such as use1-az3"
  type        = list(string)
}

variable "flow_logs_bucket_arn" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

# the only address allowed to reach the public api endpoint, passed at apply time and never committed
variable "admin_cidr" {
  type = string
}

variable "admin_role_arn" {
  description = "iam role that gets cluster admin through an access entry"
  type        = string
}

variable "cluster_secrets_key_arn" {
  type = string
}

# kyverno reads the signatures and attestations stored next to the images in this repository
variable "api_repository_arn" {
  type = string
}

variable "node_capacity_type" {
  type = string
}

# several types, so a spot shortage in one doesn't leave the cluster without nodes
variable "node_instance_types" {
  type = list(string)
}
