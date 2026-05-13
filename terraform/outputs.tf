output "public_ip" {
  description = "Elastic IP of the AFFiNE server"
  value       = aws_eip.this.public_ip
}

output "access_url" {
  description = "AFFiNE access URL (browser may warn about self-signed cert if no domain was set)"
  value       = "https://${local.public_host}"
}

output "ssh_command" {
  description = "SSH command to connect to the EC2 instance"
  value       = "ssh -i ${pathexpand(var.local_ssh_key_path)} -o StrictHostKeyChecking=no ${var.ec2_user}@${aws_eip.this.public_ip}"
}

output "setup_log_command" {
  description = "Tail the user-data setup log to monitor progress after apply"
  value       = "ssh -i ${pathexpand(var.local_ssh_key_path)} -o StrictHostKeyChecking=no ${var.ec2_user}@${aws_eip.this.public_ip} 'sudo tail -f /var/log/affine-setup.log'"
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.this.id
}

output "s3_bucket" {
  description = "S3 bucket name for AFFiNE file storage"
  value       = aws_s3_bucket.this.bucket
}

output "ssh_key_path" {
  description = "Local path to the SSH private key"
  value       = pathexpand(var.local_ssh_key_path)
}

output "ec2_user" {
  description = "EC2 OS username"
  value       = var.ec2_user
}
