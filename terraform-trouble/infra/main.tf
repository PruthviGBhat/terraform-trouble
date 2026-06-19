# =============================================================================
# CLOUDKITCHEN – MAIN TERRAFORM  (COMPLETE, PRODUCTION-READY)
# =============================================================================
#
# Architecture:
#   Internet → External ALB → Web Tier (Nginx/React) + App Tier (Spring Boot)
#                Internal ALB → App Tier → RDS PostgreSQL
#
# Key fixes vs previous version:
#   • Removed frontend EC2 web tier, now using CloudFront + S3
#   • External ALB routes directly to App Tier
#   • deletion_protection=false + skip_final_snapshot=true (safe destroy)
#   • health_check_grace_period 900s on App ASG (Maven build takes time)
#   • Removed legacy EC2-DB variables
# =============================================================================

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  # Dynamically calculate the environment prefix based on the active Terraform workspace.
  # "default" workspace acts as Production and uses the raw project name.
  # e.g., "cloudkitchen" vs "cloudkitchen-dev"
  env_prefix = terraform.workspace == "default" ? var.project_name : "${var.project_name}-${terraform.workspace}"
}

# =============================================================================
# 1. VPC & NETWORKING
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge({ Name = local.env_prefix }, var.global_tags)
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge({ Name = "${local.env_prefix}-igw" }, var.global_tags)
}

resource "aws_subnet" "public" {
  for_each = {
    az1 = { cidr = var.public_subnet_cidrs[0], az = var.availability_zones[0] }
    az2 = { cidr = var.public_subnet_cidrs[1], az = var.availability_zones[1] }
  }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags                    = merge({ Name = "${local.env_prefix}-public-${each.key}", Tier = "Public" }, var.global_tags)
}

resource "aws_subnet" "private_app" {
  for_each = {
    az1 = { cidr = var.private_app_subnet_cidrs[0], az = var.availability_zones[0] }
    az2 = { cidr = var.private_app_subnet_cidrs[1], az = var.availability_zones[1] }
  }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = merge({ Name = "${local.env_prefix}-app-${each.key}", Tier = "PrivateApp" }, var.global_tags)
}

resource "aws_subnet" "private_db" {
  for_each = {
    az1 = { cidr = var.private_db_subnet_cidrs[0], az = var.availability_zones[0] }
    az2 = { cidr = var.private_db_subnet_cidrs[1], az = var.availability_zones[1] }
  }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = merge({ Name = "${local.env_prefix}-db-${each.key}", Tier = "PrivateDB" }, var.global_tags)
}

resource "aws_eip" "nat" {
  for_each   = aws_subnet.public
  domain     = "vpc"
  tags       = merge({ Name = "${local.env_prefix}-nat-eip-${each.key}" }, var.global_tags)
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "main" {
  for_each      = aws_subnet.public
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value.id
  tags          = merge({ Name = "${local.env_prefix}-nat-${each.key}" }, var.global_tags)
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge({ Name = "${local.env_prefix}-public-rt" }, var.global_tags)
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.public
  vpc_id   = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[each.key].id
  }
  tags = merge({ Name = "${local.env_prefix}-private-rt-${each.key}" }, var.global_tags)
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  for_each       = aws_subnet.private_app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private_db" {
  for_each       = aws_subnet.private_db
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# =============================================================================
# 2. SECURITY GROUPS
# =============================================================================

# ── External ALB ─────────────────────────────
resource "aws_security_group" "ext_alb_sg" {
  name        = "${local.env_prefix}-ext-alb-sg"
  description = "External ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-ext-alb-sg" }, var.global_tags)
}

# ── App Tier: Spring Boot EC2 instances ────────────────────────────────────
resource "aws_security_group" "app_sg" {
  name        = "${local.env_prefix}-app-sg"
  description = "App Tier - Spring Boot; receives from Ext ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Spring Boot from External ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.ext_alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-app-sg" }, var.global_tags)
}

# ── Database Tier: RDS PostgreSQL ──────────────────────────────────────────
resource "aws_security_group" "db_sg" {
  name        = "${local.env_prefix}-db-sg"
  description = "DB Tier - PostgreSQL 5432 from App Tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from App Tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-db-sg" }, var.global_tags)
}

# =============================================================================
# 3. DATABASE (RDS PostgreSQL)
# =============================================================================

resource "random_password" "db_password" {
  length  = 20
  special = false # avoid special chars that break JDBC URLs
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.env_prefix}-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private_db : s.id]
  tags       = merge({ Name = "${local.env_prefix}-db-subnet-group" }, var.global_tags)
}

resource "aws_db_instance" "this" {
  identifier        = "${local.env_prefix}-db"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result
  port     = 5432

  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.this.name
  multi_az               = false # set true for HA in production

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # FIX: Keep both false so terraform destroy completes without RDS state issues
  deletion_protection = false
  skip_final_snapshot = true

  # Performance Insights (free tier for db.t3.micro)
  performance_insights_enabled = false

  tags = merge({ Name = "${local.env_prefix}-rds" }, var.global_tags)
}

# =============================================================================
# 4. SECRETS MANAGER & SSM PARAMETER STORE
# =============================================================================

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.env_prefix}/db/credentials-new"
  description             = "RDS PostgreSQL credentials for CloudKitchen App Tier"
  recovery_window_in_days = 0 # allow immediate delete (useful for re-deployments)
  tags                    = var.global_tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.this.address
    port     = 5432
    dbname   = var.db_name
  })
}

resource "aws_ssm_parameter" "cors_origins" {
  name  = "/${local.env_prefix}/app/cors_origins"
  type  = "String"
  value = var.cors_origins
  tags  = var.global_tags
}



# =============================================================================
# 5. LOAD BALANCERS & TARGET GROUPS
# =============================================================================

# ── External (internet-facing) ALB ────────────────────────────────────────
resource "aws_lb" "external" {
  name               = "${local.env_prefix}-ext-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ext_alb_sg.id]
  subnets            = [for s in aws_subnet.public : s.id]

  enable_deletion_protection = false
  idle_timeout               = 60

  tags = merge({ Name = "${local.env_prefix}-ext-alb" }, var.global_tags)
}

# ── Target Group: App via External ALB (port 8080) ────────────────────────
resource "aws_lb_target_group" "app_tg" {
  name     = "${local.env_prefix}-app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/api/categories"
    port                = "traffic-port"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }

  tags = var.global_tags
}

# ── External ALB Listeners ────────────────────────────────────────────────
resource "aws_lb_listener" "ext_http" {
  load_balancer_arn = aws_lb.external.arn
  port              = 80
  protocol          = "HTTP"

  # Default: all traffic → App Tier
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# =============================================================================
# 6. IAM – App Tier Instance Role
# =============================================================================

resource "aws_iam_role" "app_role" {
  name = "${local.env_prefix}-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.global_tags
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app_secrets_policy" {
  name = "${local.env_prefix}-app-secrets-policy"
  role = aws_iam_role.app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDBSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.db.arn
      },
      {
        Sid      = "ReadSSMParams"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.env_prefix}/*"
      },
      {
        # Menu service downloads its deployment zip (menu_service.zip) from S3 on boot.
        # Without this, user-data fails with 403 Forbidden and the service never starts.
        Sid      = "ReadDeploymentArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.testimonials.arn}/*"
      },
      {
        Sid      = "ListDeploymentBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.testimonials.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/cloudkitchen/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "${local.env_prefix}-app-profile"
  role = aws_iam_role.app_role.name
}

# =============================================================================
# 7. COMPUTE – Launch Templates & Auto Scaling Groups
# =============================================================================


# ── App Tier Launch Template ───────────────────────────────────────────────
resource "aws_launch_template" "app" {
  name          = "${local.env_prefix}-app-lt"
  image_id      = var.app_ami_id
  instance_type = var.app_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.app_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app_profile.name
  }

  user_data = base64encode(templatefile("${path.module}/userdata/menu.sh", {
    s3_bucket     = aws_s3_bucket.testimonials.bucket
    db_secret_arn = aws_secretsmanager_secret.db.arn
    aws_region    = var.aws_region
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = "${local.env_prefix}-app" }, var.global_tags)
  }

  tags = var.global_tags
}


# ── App ASG ────────────────────────────────────────────────────────────────
# FIX: health_check_grace_period = 900 (15 min) to allow:
#   apt-get (2min) + git clone (1min) + Maven build/download (8min) + Spring startup (2min)
resource "aws_autoscaling_group" "app" {
  name                      = "${local.env_prefix}-app-asg"
  vpc_zone_identifier       = [for s in aws_subnet.private_app : s.id]
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  health_check_type         = "ELB"
  health_check_grace_period = 1200 # 20 min – headroom for cold Maven build + JVM start on t3.small (prevents kill-mid-build cycling)
  target_group_arns = [
    aws_lb_target_group.app_tg.arn
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.env_prefix}-app"
    propagate_at_launch = true
  }

  depends_on = [
    aws_nat_gateway.main,
    aws_db_instance.this,
    aws_secretsmanager_secret_version.db,
    aws_s3_object.menu_service_code,
  ]
}

# =============================================================================
# 8. S3 BUCKET (DB Backups)
# =============================================================================

resource "aws_s3_bucket" "backups" {
  bucket        = "${local.env_prefix}-db-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # allow destroy without emptying manually
  tags          = var.global_tags
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }
  }
}

# =============================================================================
# 9. CLOUDWATCH LOG GROUP (App Tier)
# =============================================================================

resource "aws_cloudwatch_log_group" "app" {
  name              = "/cloudkitchen/app"
  retention_in_days = 30
  tags              = var.global_tags
}

# =============================================================================
# 10. PACKAGE & UPLOAD MENU SERVICE CODE TO S3
# =============================================================================

data "archive_file" "menu_service_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../services/menu-service"
  output_path = "${path.module}/menu_service.zip"
}

resource "aws_s3_object" "menu_service_code" {
  bucket = aws_s3_bucket.testimonials.id
  key    = "deployments/menu_service.zip"
  source = data.archive_file.menu_service_zip.output_path
  etag   = filemd5(data.archive_file.menu_service_zip.output_path)
}
