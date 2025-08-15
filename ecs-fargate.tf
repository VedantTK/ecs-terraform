# ecs-fargate.tf (fixed: removed launch_type to avoid API conflict)
data "aws_ecr_repository" "existing" {
  count = var.ecr_repo_url == "" ? 1 : 0
  name  = var.ecr_repo_name
}

locals {
  ecr_repo_url = var.ecr_repo_url != "" ? var.ecr_repo_url : (var.ecr_repo_name != "" ? data.aws_ecr_repository.existing[0].repository_url : var.initial_image)
}

# ECS cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.env}-cluster"
}

# IAM role for task execution
resource "aws_iam_role" "task_exec_role" {
  name = "${var.project}-${var.env}-task-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_exec_attachment" {
  role       = aws_iam_role.task_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch Logs group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}-${var.env}"
  retention_in_days = 14
}

# Task definition
resource "aws_ecs_task_definition" "task" {
  family                   = "${var.project}-${var.env}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"   # 0.25 vCPU
  memory                   = "512"   # 0.5 GB
  execution_role_arn       = aws_iam_role.task_exec_role.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = local.ecr_repo_url
      essential = true
      portMappings = [{ containerPort = var.container_port, hostPort = var.container_port, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

# Security Group that allows inbound HTTP to the task
resource "aws_security_group" "svc_sg" {
  name   = "${var.project}-${var.env}-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow inbound HTTP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.env}-sg" }
}

# ECS Service (no ALB), tasks get public IP from the single public subnet
resource "aws_ecs_service" "svc" {
  name            = "${var.project}-${var.env}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 1

  network_configuration {
    subnets         = [aws_subnet.public.id]
    security_groups = [aws_security_group.svc_sg.id]
    assign_public_ip = true   # boolean
  }

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  lifecycle {
    ignore_changes = [task_definition] # CI will update the task definition (register new revisions)
  }

  depends_on = [aws_iam_role_policy_attachment.task_exec_attachment]
}
