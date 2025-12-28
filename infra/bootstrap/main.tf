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

# --------------------------------------------------------------------------------------------------
# 4) Cost Monitoring (Budgets + SNS + Chatbot)
# --------------------------------------------------------------------------------------------------

# SNS Topic: Budget からの通知を受け取る窓口
resource "aws_sns_topic" "budget_notifications" {
  name = "${var.project}-budget-notifications"
}

# SNS Topic Policy: AWS Budgets がこの Topic に Publish できるように許可
resource "aws_sns_topic_policy" "budget_notifications" {
  arn    = aws_sns_topic.budget_notifications.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    actions = ["sns:Publish"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    resources = [aws_sns_topic.budget_notifications.arn]
  }
}

# AWS Budgets: 予算設定
resource "aws_budgets_budget" "monthly_cost" {
  name              = "${var.project}-monthly-budget"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_usd
  limit_unit        = "USD"
  time_period_start = "2024-01-01_00:00"
  time_unit         = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_notifications.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_notifications.arn]
  }
}

# AWS Chatbot: Slack 連携
# 注意: 初回のみ、AWSコンソールで Slack Workspace を認証（Configure client）しておく必要があります。
resource "aws_iam_role" "chatbot" {
  name = "${var.project}-chatbot-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "chatbot.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "chatbot_readonly" {
  role       = aws_iam_role.chatbot.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_chatbot_slack_channel_configuration" "budget_alerts" {
  configuration_name = "${var.project}-budget-alerts"
  iam_role_arn       = aws_iam_role.chatbot.arn
  slack_channel_id   = var.slack_channel_id
  slack_workspace_id = var.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.budget_notifications.arn]
}
