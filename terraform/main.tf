data "aws_caller_identity" "current" {}

data "http" "my_ip" {
  count = var.ssh_allowed_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  s3_bucket         = "${var.project}-files-${local.account_id}"
  az                = "${var.aws_region}a"
  ssh_cidr          = var.ssh_allowed_cidr != "" ? var.ssh_allowed_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"
  public_host       = var.affine_domain != "" ? var.affine_domain : aws_eip.this.public_ip
  nginx_server_name = var.affine_domain != "" ? var.affine_domain : "_"
}

resource "aws_vpc" "this" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project}-vpc"
    Project = var.project
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name    = "${var.project}-igw"
    Project = var.project
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project}-public-subnet"
    Project = var.project
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name    = "${var.project}-rt"
    Project = var.project
  }
}

resource "aws_route_table_association" "public" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public.id
}

resource "aws_security_group" "this" {
  name        = "${var.project}-sg"
  description = "AFFiNE demo - HTTPS public, SSH restricted"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP (Nginx redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH restricted to deployer IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project}-sg"
    Project = var.project
  }
}
