resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.this.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.this.private_key_pem
  filename        = pathexpand(var.local_ssh_key_path)
  file_permission = "0400"
}

resource "random_password" "postgres" {
  length  = 48
  special = false
}

resource "random_password" "affine_secret" {
  length  = 64
  special = false
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_eip" "this" {
  domain = "vpc"

  tags = {
    Name    = "${var.project}-eip"
    Project = var.project
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  key_name               = aws_key_pair.this.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    ec2_user          = var.ec2_user
    affine_dir        = "/opt/affine"
    affine_revision   = "stable"
    postgres_password = random_password.postgres.result
    affine_secret     = random_password.affine_secret.result
    s3_bucket         = local.s3_bucket
    s3_region         = var.aws_region
    public_host       = local.public_host
    nginx_server_name = local.nginx_server_name
    affine_domain     = var.affine_domain
  })

  user_data_replace_on_change = true

  # hop_limit=2 lets Docker containers reach the IMDSv2 endpoint
  # (container → bridge → host counts as 2 hops)
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project}-server"
    Project = var.project
  }
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}
