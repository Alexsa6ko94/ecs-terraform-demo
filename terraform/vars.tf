variable "aws_region" {}
variable "aws_access_key_id" {}
variable "aws_secret_access_key" {}

variable "aws_zones" {
  type        = "list"
  description = "List of availability zones to use"
  default     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

