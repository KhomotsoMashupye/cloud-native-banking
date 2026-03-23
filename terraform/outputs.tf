output "rds_endpoint" {
  value = aws_db_instance.primary_db.endpoint
}
output "ecr_repository_url" {
  value = aws_ecr_repository.banking_app_repo.repository_url
}