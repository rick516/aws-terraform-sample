############################################
# Provider / Tags
############################################

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # 残骸検索しやすいように全リソースへタグを自動付与
  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "terraform"
      Purpose   = "aws-catchup-sample"
    }
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name = "${var.project}-${var.env}"
}

############################################
# Network (VPC)
############################################

# 意図:
# - ALB は public subnet に置き、インターネットから入れる
# - ECS/RDS/Redis は private subnet に置き、外部から直接触れない
# - private subnet から ECR pull や package download できるよう NAT を置く（コストはかかる）
data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.3"

  name = local.name
  cidr = "10.10.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.10.0.0/24", "10.10.1.0/24"]
  private_subnets = ["10.10.10.0/24", "10.10.11.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true
}

############################################
# Security Groups
############################################

# ALB SG: インターネットからHTTPを受ける
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB inbound from allowed CIDRs"
  vpc_id      = module.vpc.vpc_id
}

# allowed_cidrs 分だけ ingress rule を作る
resource "aws_vpc_security_group_ingress_rule" "alb_in_http" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_out_all" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# App SG: ALB からの通信だけ受ける（ECS tasks用）
resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "App tasks inbound from ALB only"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "app_in_from_alb" {
  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_out_all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# DB SG: App tasks からの接続のみ許可
resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "DB inbound from app tasks only"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_in_from_app" {
  security_group_id            = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_engine == "postgres" ? 5432 : 3306
  to_port                      = var.db_engine == "postgres" ? 5432 : 3306
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "db_out_all" {
  security_group_id = aws_security_group.db.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Redis SG: worker/api からの接続のみ許可
resource "aws_security_group" "redis" {
  name        = "${local.name}-redis-sg"
  description = "Redis inbound from app tasks only"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_in_from_app" {
  security_group_id            = aws_security_group.redis.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "redis_out_all" {
  security_group_id = aws_security_group.redis.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

############################################
# ECR Repositories
############################################

# 意図:
# - コンテナイメージを置く場所
# - 検証後に消したいので force_delete=true（中にイメージが残っていても削除できる）
resource "aws_ecr_repository" "api" {
  name         = "${local.name}-api"
  force_delete = true
}

resource "aws_ecr_repository" "worker" {
  name         = "${local.name}-worker"
  force_delete = true
}

resource "aws_ecr_repository" "web" {
  name         = "${local.name}-web"
  force_delete = true
}

############################################
# CloudWatch Logs
############################################

# 意図:
# - コンテナの標準出力/標準エラーを CloudWatch Logs に流して、現場っぽい調査ができるようにする
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}/api"
  retention_in_days = 3
}
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${local.name}/worker"
  retention_in_days = 3
}
resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/${local.name}/web"
  retention_in_days = 3
}

############################################
# Secrets Manager (DB password)
############################################

# 意図:
# - DBパスワードを terraform の平文変数で持たない
# - ECS task definition の secrets 経由で環境変数として注入する
resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "_%@"
}

resource "aws_secretsmanager_secret" "db_password" {
  name = "${local.name}-db-password"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result
}

############################################
# RDS (Postgres/MySQL)
############################################

# 意図:
# - transaction/台帳データの保存先として RDB を置く（審査・監査っぽさ）
# - 検証環境なので削除しやすい設定にする（skip_final_snapshot など）
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "main" {
  identifier = "${local.name}-db-${random_string.suffix.result}"

  engine         = var.db_engine
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name                = var.db_name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  username = "app"
  password = random_password.db_password.result

  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true
  apply_immediately        = true
}

############################################
# ElastiCache Redis (Sidekiq用の雰囲気)
############################################

resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name}-redis-subnets"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${local.name}-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"

  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]
}

############################################
# ALB
############################################

# 意図:
# - インターネットからの入口を一つに集約
# - /api/* を Rails(API) に、その他を Next(SSR) にルーティングする
resource "aws_lb" "app" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group" "web" {
  name        = "${local.name}-web-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# /api/* は API target group に転送
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern {
      values = ["/api/*", "/healthz"]
    }
  }
}

############################################
# ECS Cluster / IAM Roles
############################################

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"
}

# ECS Task Execution Role
# 意図:
# - ECSエージェントが ECR pull / CloudWatch Logs 出力 / Secrets取得 をするための権限
resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name}-ecs-task-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = "sts:AssumeRole",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets Manager から secret を読む権限は追加で必要になることがあるので明示的に付与
resource "aws_iam_policy" "ecs_exec_secrets" {
  name = "${local.name}-ecs-secrets"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["secretsmanager:GetSecretValue"],
      Resource = [aws_secretsmanager_secret.db_password.arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_secrets" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.ecs_exec_secrets.arn
}

# ECS Task Role
# 意図:
# - アプリケーションコードが AWS API を叩くときの権限（最初は空でも良い）
resource "aws_iam_role" "ecs_task" {
  name = "${local.name}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = "sts:AssumeRole",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

############################################
# ECS Task Definitions
############################################

# api (Railsの代わりに http-echo で疎通)
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "api"
    image = var.api_image

    essential = true

    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]

    # http-echo 用。Railsに差し替えたら command は不要
    command = ["-listen=:3000", "-text=api ok"]

    environment = [
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_USER", value = "app" },
      { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379/0" }
    ]

    secrets = [
      { name = "DB_PASSWORD", valueFrom = aws_secretsmanager_secret.db_password.arn }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "api"
      }
    }
  }])
}

# web (Next SSR の代わりに http-echo)
resource "aws_ecs_task_definition" "web" {
  family                   = "${local.name}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "web"
    image = var.web_image

    essential = true

    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]

    command = ["-listen=:3000", "-text=web ok"]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.web.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "web"
      }
    }
  }])
}

# worker (Sidekiq の代わりに busybox でログを出すだけ)
resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "worker"
    image = var.worker_image
    essential = true

    # ずっとログを吐き続けるだけ
    command = ["sh", "-c", "while true; do echo worker running; sleep 30; done"]

    environment = [
      { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379/0" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "worker"
      }
    }
  }])
}

############################################
# ECS Services
############################################

resource "aws_ecs_service" "api" {
  name            = "${local.name}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # 意図:
  # - デプロイが失敗したら自動で前の安定版に戻す
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # CI/CD 側で task definition を更新する運用にするので、Terraform が巻き戻さないよう ignore する
  lifecycle {
    ignore_changes = [task_definition]
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "web" {
  name            = "${local.name}-web"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "worker" {
  name            = "${local.name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
}
