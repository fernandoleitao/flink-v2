variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "flink-poc"
}

variable "github_repo" {
  description = "GitHub repository in the format owner/repo (used for OIDC trust policy)"
  type        = string
  # e.g. "octocat/flink-v2"
}
