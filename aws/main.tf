terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.13.0"
    }
  }
}

provider "aws" {
  region = var.default_region
  default_tags {
    tags = {
      TestedBy = var.tested_by
    }
  }
}

variable "aws_account_id" {
  type        = string
  description = "AWSのアカウントID"
}

variable "default_region" {
  type        = string
  description = "デフォルトのリージョン"
}

variable "tested_by" {
  type        = string
  description = "検証担当者"
}

variable "trocco_registration_token" {
  type        = string
  description = "TROCCO Self-Hosted-RunnerのRegistration Token"
  sensitive   = true
}

variable "trocco_shr_image_url" {
  type        = string
  description = "TROCCO Self-Hosted-RunnerのコンテナイメージURL"
}

# VPC
resource "aws_vpc" "trocco_self_hosted_runner" {
  cidr_block = "10.0.0.0/16"
}

# サブネット
resource "aws_subnet" "trocco_self_hosted_runner" {
  vpc_id            = aws_vpc.trocco_self_hosted_runner.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.default_region}a"
}

# インターネットゲートウェイ
resource "aws_internet_gateway" "trocco_self_hosted_runner" {
  vpc_id = aws_vpc.trocco_self_hosted_runner.id
}

# インターネットゲートウェイへのルート
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.trocco_self_hosted_runner.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.trocco_self_hosted_runner.id
  }
}

# サブネットとルートテーブルの関連付け
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.trocco_self_hosted_runner.id
  route_table_id = aws_route_table.public.id
}

# セキュリティグループ
resource "aws_security_group" "trocco_self_hosted_runner" {
  name        = "trocco_self_hosted_runner"
  description = "Security group for TROCCO Self-Hosted Runner"
  vpc_id      = aws_vpc.trocco_self_hosted_runner.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SSM Parameter StoreにRegistration Tokenを保存
resource "aws_ssm_parameter" "trocco_registration_token" {
  name  = "trocco_self_hosted_runner_registration_token"
  type  = "SecureString"
  value = var.trocco_registration_token
}

# CloudWatch Logsのロググループ
resource "aws_cloudwatch_log_group" "trocco_self_hosted_runner" {
  name              = "/ecs/trocco-self-hosted-runner"
  retention_in_days = 7
}

# ECS(Fargate)用のIAMロール
resource "aws_iam_role" "trocco_self_hosted_runner" {
  name = "TROCCOSelfHostedRunnerRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# ECS(Fargate)用のIAMポリシー
resource "aws_iam_policy" "trocco_self_hosted_runner" {
  name = "TROCCOSelfHostedRunner"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowSSMParameterAccess",
        Effect = "Allow",
        Action = ["ssm:GetParameter", "ssm:GetParameters"],
        Resource = [
          aws_ssm_parameter.trocco_registration_token.arn
        ]
      },
      {
        Sid      = "AllowKMSDecrypt",
        Effect   = "Allow",
        Action   = "kms:Decrypt",
        Resource = "arn:aws:kms:${var.default_region}:${var.aws_account_id}:alias/aws/ssm"
      },
      {
        Sid    = "CreateLogStreamAndPutLogEvents",
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.default_region}:${var.aws_account_id}:log-group:${aws_cloudwatch_log_group.trocco_self_hosted_runner.name}*"
      }
    ]
  })
}

# IAMロールとポリシーの関連付け
resource "aws_iam_role_policy_attachment" "trocco_self_hosted_runner" {
  role       = aws_iam_role.trocco_self_hosted_runner.name
  policy_arn = aws_iam_policy.trocco_self_hosted_runner.arn
}

# ECSクラスタ、タスク定義、サービス
resource "aws_ecs_cluster" "trocco_self_hosted_runner" {
  name = "trocco-self-hosted-runner"
}

# ECSタスク定義
resource "aws_ecs_task_definition" "trocco_self_hosted_runner" {
  family                   = "trocco-self-hosted-runner"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.trocco_self_hosted_runner.arn
  cpu                      = "1024"
  memory                   = 2048
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # X86_64も対応
  }
  container_definitions = jsonencode([
    {
      name      = "trocco-self-hosted-runner"
      image     = "${var.trocco_shr_image_url}:latest"
      essential = true
      environment = [
        {
          name  = "TROCCO_PREVIEW_SEND"
          value = "true"
        },
      ]
      secrets = [
        {
          name      = "TROCCO_REGISTRATION_TOKEN"
          valueFrom = aws_ssm_parameter.trocco_registration_token.arn
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.trocco_self_hosted_runner.name
          awslogs-region        = var.default_region
          awslogs-stream-prefix = "trocco-shr"
        }
      }
    }
  ])
}

# ECSサービス
resource "aws_ecs_service" "trocco_self_hosted_runner" {
  name             = "trocco-self-hosted-runner"
  cluster          = aws_ecs_cluster.trocco_self_hosted_runner.id
  launch_type      = "FARGATE"
  platform_version = "LATEST"
  desired_count    = 1
  task_definition  = aws_ecs_task_definition.trocco_self_hosted_runner.arn
  network_configuration {
    assign_public_ip = true
    security_groups = [
      aws_security_group.trocco_self_hosted_runner.id,
    ]
    subnets = [
      aws_subnet.trocco_self_hosted_runner.id,
    ]
  }
}
