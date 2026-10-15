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
