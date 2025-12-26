variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "ローカルでterraform applyするときのAWS profile。CIでは使わない"
  type        = string
  default     = "aws-terraform-sample"
}

variable "project" {
  description = "リソース名接頭辞"
  type        = string
  default     = "aws-terraform-sample"
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "allowed_cidrs" {
  description = "ALB に入ってよい CIDR。最初は 0.0.0.0/0 で良いが、後で自分のIP/32に絞ると良い"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# 初期デプロイ用のダミーイメージ（後でECRに差し替える）
variable "api_image" {
  type    = string
  default = "hashicorp/http-echo:1.0.0"
}
variable "web_image" {
  type    = string
  default = "hashicorp/http-echo:1.0.0"
}
variable "worker_image" {
  type    = string
  default = "public.ecr.aws/docker/library/busybox:latest"
}

variable "db_engine" {
  description = "postgres か mysql。現場っぽさでいうと両対応できると強い"
  type        = string
  default     = "postgres"
}

variable "db_name" {
  description = "RDSの初期DB名"
  type        = string
  default     = "app"
}
