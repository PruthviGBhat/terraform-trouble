# =============================================================================
# AUTH SERVICE INFRASTRUCTURE
# AWS Cognito User Pools + FastAPI Auth Microservice
#
# Microservice routing (ALB priority order):
#   40 → /auth/*              Auth Service  (port 8001)  [this file]
#   50 → /api/recommend*      AI Service    (port 8000)  [ai-infrastructure.tf]
#   default → /*              App Service   (port 8080)  [main.tf]
# =============================================================================

# ---------------------------------------------------------------------------
# 1. PACKAGE & UPLOAD AUTH SERVICE CODE TO S3 (same pattern as AI service)
# ---------------------------------------------------------------------------

data "archive_file" "auth_service_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../services/auth-service"
  output_path = "${path.module}/auth_service.zip"
}

resource "aws_s3_object" "auth_service_code" {
  bucket = aws_s3_bucket.testimonials.id
  key    = "deployments/auth_service.zip"
  source = data.archive_file.auth_service_zip.output_path
  etag   = filemd5(data.archive_file.auth_service_zip.output_path)
}

# ---------------------------------------------------------------------------
# 2. COGNITO – Customer User Pool
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "users" {
  name = "${local.env_prefix}-users"

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  auto_verified_attributes = ["email"]

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 100
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  tags = merge({ Name = "${local.env_prefix}-users-pool" }, var.global_tags)
}

resource "aws_cognito_user_pool_client" "users" {
  name         = "${local.env_prefix}-users-client"
  user_pool_id = aws_cognito_user_pool.users.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  generate_secret = false
}

# ---------------------------------------------------------------------------
# 3. COGNITO – Restaurant User Pool
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "restaurants" {
  name = "${local.env_prefix}-restaurants"

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  auto_verified_attributes = ["email"]

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 100
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  schema {
    name                     = "restaurant_name"
    attribute_data_type      = "String"
    required                 = false
    mutable                  = true
    developer_only_attribute = false
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  tags = merge({ Name = "${local.env_prefix}-restaurants-pool" }, var.global_tags)
}

resource "aws_cognito_user_pool_client" "restaurants" {
  name         = "${local.env_prefix}-restaurants-client"
  user_pool_id = aws_cognito_user_pool.restaurants.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  generate_secret = false
}

# ---------------------------------------------------------------------------
# 4. SSM PARAMETERS – Cognito IDs (reachable by any service via IAM)
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "user_pool_id" {
  name  = "/${local.env_prefix}/cognito/user_pool_id"
  type  = "String"
  value = aws_cognito_user_pool.users.id
  tags  = var.global_tags
}

resource "aws_ssm_parameter" "user_client_id" {
  name  = "/${local.env_prefix}/cognito/user_client_id"
  type  = "String"
  value = aws_cognito_user_pool_client.users.id
  tags  = var.global_tags
}

resource "aws_ssm_parameter" "restaurant_pool_id" {
  name  = "/${local.env_prefix}/cognito/restaurant_pool_id"
  type  = "String"
  value = aws_cognito_user_pool.restaurants.id
  tags  = var.global_tags
}

resource "aws_ssm_parameter" "restaurant_client_id" {
  name  = "/${local.env_prefix}/cognito/restaurant_client_id"
  type  = "String"
  value = aws_cognito_user_pool_client.restaurants.id
  tags  = var.global_tags
}

# ---------------------------------------------------------------------------
# 5. SECURITY GROUP – Auth Tier (port 8001, traffic from ALB only)
# ---------------------------------------------------------------------------

resource "aws_security_group" "auth_sg" {
  name        = "${local.env_prefix}-auth-sg"
  description = "Auth Tier - FastAPI; receives from Ext ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Auth Service from External ALB"
    from_port       = 8001
    to_port         = 8001
    protocol        = "tcp"
    security_groups = [aws_security_group.ext_alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-auth-sg" }, var.global_tags)
}

# ---------------------------------------------------------------------------
# 6. IAM ROLE – Auth Service (Cognito + S3 + CloudWatch)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "auth_role" {
  name = "${local.env_prefix}-auth-role"

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

resource "aws_iam_role_policy_attachment" "auth_ssm" {
  role       = aws_iam_role.auth_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "auth_policy" {
  name = "${local.env_prefix}-auth-policy"
  role = aws_iam_role.auth_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CognitoAuth"
        Effect = "Allow"
        Action = [
          "cognito-idp:SignUp",
          "cognito-idp:AdminConfirmSignUp",
          "cognito-idp:InitiateAuth",
        ]
        Resource = [
          aws_cognito_user_pool.users.arn,
          aws_cognito_user_pool.restaurants.arn,
        ]
      },
      {
        Sid      = "ReadS3Code"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.testimonials.arn}/*"]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/cloudkitchen/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "auth_profile" {
  name = "${local.env_prefix}-auth-profile"
  role = aws_iam_role.auth_role.name
}

# ---------------------------------------------------------------------------
# 7. LAUNCH TEMPLATE – Auth Tier (t3.small, Ubuntu 22.04, same as AI tier)
# ---------------------------------------------------------------------------

resource "aws_launch_template" "auth_lt" {
  name_prefix   = "${local.env_prefix}-auth-lt-"
  image_id      = "ami-0326c8c1e2d6bf78c" # Ubuntu 22.04 LTS ap-south-1
  instance_type = "t3.small"

  iam_instance_profile {
    name = aws_iam_instance_profile.auth_profile.name
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }

  vpc_security_group_ids = [aws_security_group.auth_sg.id]

  user_data = base64encode(templatefile("${path.module}/userdata/auth.sh", {
    s3_bucket            = aws_s3_bucket.testimonials.bucket
    user_pool_id         = aws_cognito_user_pool.users.id
    user_client_id       = aws_cognito_user_pool_client.users.id
    restaurant_pool_id   = aws_cognito_user_pool.restaurants.id
    restaurant_client_id = aws_cognito_user_pool_client.restaurants.id
    aws_region           = var.aws_region
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = "${local.env_prefix}-auth-server" }, var.global_tags)
  }
}

# ---------------------------------------------------------------------------
# 8. TARGET GROUP – Auth Service (port 8001, health check /auth/health)
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "auth_tg" {
  name     = "${local.env_prefix}-auth-tg"
  port     = 8001
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/auth/health"
    port                = "traffic-port"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }

  tags = var.global_tags
}

# ---------------------------------------------------------------------------
# 9. AUTO SCALING GROUP – Auth Tier (1-2 instances, 5 min grace)
# ---------------------------------------------------------------------------

resource "aws_autoscaling_group" "auth_asg" {
  name                      = "${local.env_prefix}-auth-asg"
  vpc_zone_identifier       = [for s in aws_subnet.private_app : s.id]
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  health_check_type         = "ELB"
  health_check_grace_period = 900 # 15 min – Maven build + Spring Boot cold start

  target_group_arns = [aws_lb_target_group.auth_tg.arn]

  launch_template {
    id      = aws_launch_template.auth_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.env_prefix}-auth-server"
    propagate_at_launch = true
  }

  depends_on = [
    aws_nat_gateway.main,
    aws_s3_object.auth_service_code,
  ]
}

# ---------------------------------------------------------------------------
# 10. ALB LISTENER RULE – /auth/* → Auth Service (priority 40)
# ---------------------------------------------------------------------------

resource "aws_lb_listener_rule" "auth_rule" {
  listener_arn = aws_lb_listener.ext_http.arn
  priority     = 40

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.auth_tg.arn
  }

  condition {
    path_pattern {
      values = ["/auth/*"]
    }
  }
}

# ---------------------------------------------------------------------------
# 11. CLOUDWATCH LOG GROUP – Auth Service
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "auth" {
  name              = "/cloudkitchen/auth"
  retention_in_days = 30
  tags              = var.global_tags
}
