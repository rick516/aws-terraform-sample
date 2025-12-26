output "tfstate_bucket" {
  value       = aws_s3_bucket.tfstate.bucket
  description = "env/dev の backend.tf で指定する S3 bucket 名"
}

output "aws_region" {
  value       = var.aws_region
  description = "backend.tf の region と workflow の AWS_REGION に使う"
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "GitHub Actions が assume する role arn（workflow の role-to-assume）"
}
