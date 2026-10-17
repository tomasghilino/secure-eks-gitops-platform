variable "region" {
  type    = string
  default = "us-east-1"
}

# the address of whoever runs the apply, for example $(curl -s https://checkip.amazonaws.com)/32
variable "admin_cidr" {
  type = string
}
