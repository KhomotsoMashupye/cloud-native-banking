
output "rds_hostname" {
  description = "The hostname of the RDS instance"
  value       = aws_db_instance.primary_db.address
}

output "rds_endpoint" {
  description = "The connection endpoint for the RDS instance"
  value       = aws_db_instance.primary_db.endpoint
}

output "rds_port" {
  description = "The port the database is listening on"
  value       = aws_db_instance.primary_db.port
}

output "ecr_repository_url" {
  description = "The URL of the ECR repository for Docker pushes"
  value       = aws_ecr_repository.banking_app_repo.repository_url
}

output "kms_key_arn" {
  description = "The ARN of the master KMS key used for encryption"
  value       = aws_kms_key.banking_key.arn
}

output "cluster_name" {
  description = "The name of the EKS Cluster"
  value       = aws_eks_cluster.eks_cluster.name
}

output "cluster_endpoint" {
  description = "The endpoint for your EKS Kubernetes API"
  value       = aws_eks_cluster.eks_cluster.endpoint
}

output "analytics_lake_bucket" {
  description = "The name of the S3 Analytics Data Lake"
  value       = aws_s3_bucket.analytics_lake.id
}