variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "affine-demo"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed SSH access (e.g. '203.0.113.42/32'). Leave empty to auto-detect your current public IP."
  type        = string
  default     = ""
}

variable "affine_domain" {
  description = "Optional custom domain for HTTPS (e.g. 'affine.example.com'). Leave empty to use the Elastic IP with a self-signed cert."
  type        = string
  default     = ""
}

variable "ec2_instance_type" {
  description = "EC2 instance type. t2.micro stays within Free Tier."
  type        = string
  default     = "t2.micro"
}

variable "ec2_user" {
  description = "EC2 OS username (ec2-user for Amazon Linux 2023)"
  type        = string
  default     = "ec2-user"
}

variable "local_ssh_key_path" {
  description = "Local filesystem path where the generated SSH private key is written"
  type        = string
  default     = "~/.ssh/affine-demo-key.pem"
}
