output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "ecr_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "gha_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume"
  value       = aws_iam_role.gha.arn
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}
