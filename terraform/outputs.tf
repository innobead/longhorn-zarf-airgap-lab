output "instance_id" {
  value = aws_instance.node.id
}

output "region" {
  value = var.region
}

output "bucket" {
  value = aws_s3_bucket.lab.id
}

output "ssm_shell" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.node.id}"
}

output "longhorn_ui_tunnel" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.node.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=30080,localPortNumber=8080"
}

output "airgap" {
  value = var.airgap
}
