variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "aws cli の profile 名。ローカルで bootstrap apply するときに使う"
  type        = string
  default     = "aws-terraform-sample"
}

variable "project" {
  description = "リソース名の接頭辞。削除時の残骸検索にも使う"
  type        = string
  default     = "aws-terraform-sample"
}

variable "env" {
  description = "環境名。devだけでも良い"
  type        = string
  default     = "dev"
}

# GitHub Actions OIDC を安全に使うため、どのrepoがAssumeできるかを絞る
variable "github_org" {
  description = "GitHub organization/user 名（例: yourname）"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository 名（例: riskdog-sample）"
  type        = string
}

variable "github_branch" {
  description = "デプロイを許可するブランチ（例: main）"
  type        = string
  default     = "main"
}
