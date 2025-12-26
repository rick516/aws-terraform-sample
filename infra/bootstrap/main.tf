provider "aws" {
  region  = var.aws_region
  # profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "terraform"
      Purpose   = "aws-catchup-sample"
    }
  }
}

# GitHub OIDC Provider の thumbprint は固定値にしない方が安全なので、
# Terraformの tls_certificate で https://token.actions.githubusercontent.com の証明書を取得して SHA1 fingerprint を使う
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# 1) Terraform state 用 S3 bucket
# 意図:
# - state をローカルに置かず、消し忘れやPC破損で困らないようにする
# - ただし、このテンプレは「検証後に全消し」前提なので force_destroy=true にしている
resource "aws_s3_bucket" "tfstate" {
  bucket        = "${var.project}-${var.env}-tfstate-${random_string.suffix.result}"
  force_destroy = true
}

# state は消失すると困るので versioning を有効化しておく
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# at-rest 暗号化（AES256）を有効化
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# public access を全面ブロック
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2) GitHub Actions OIDC Provider
# 意図:
# - GitHub Actions から AWS にログインするとき、長期的な AccessKey を GitHub に置かない
# - GitHub の OIDC token を AWS 側で信頼して、一時クレデンシャルを払い出す
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# 3) GitHub Actions が Assume する Role
# 意図:
# - この role を Assume できるのは指定 repo/branch の workflow だけ、に絞る
# - 権限は最初は AdministratorAccess を付けて躓きを減らし、
#   慣れてきたら最小権限に絞る（現場なら必須）
data "aws_iam_policy_document" "github_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # GitHub docs が推奨する sub/aud の条件で、repo/branch を絞る
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-${var.env}-gha"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json
}

resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
