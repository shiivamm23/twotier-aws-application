variable "aws_region" {
  type    = string
  default = "ap-south-1" # Mumbai
}

variable "project" {
  type    = string
  default = "twotier"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "desired_count" {
  type    = number
  default = 2
}
