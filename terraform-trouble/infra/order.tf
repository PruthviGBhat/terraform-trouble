# =============================================================================
# ORDER SERVICE INFRASTRUCTURE
# Spring Boot | /api/orders* | Port 8082 | ALB priority 20
#
# Final ALB routing table:
#   Priority 20  /api/orders*          → Order Service  :8082  (this file)
#   Priority 40  /auth/*               → Auth Service   :8001  (auth-infrastructure.tf)
#   Priority 50  /api/recommend*       → AI Service     :8000  (ai-infrastructure.tf)
#   Default      /*                    → Menu Service   :8080  (main.tf)
# =============================================================================

# ---------------------------------------------------------------------------
# 1. PACKAGE & UPLOAD ORDER SERVICE CODE TO S3
# ---------------------------------------------------------------------------

data "archive_file" "order_service_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../services/order-service"
  output_path = "${path.module}/order_service.zip"
}

resource "aws_s3_object" "order_service_code" {
  bucket = aws_s3_bucket.testimonials.id
  key    = "deployments/order_service.zip"
  source = data.archive_file.order_service_zip.output_path
  etag   = filemd5(data.archive_file.order_service_zip.output_path)
}

# ---------------------------------------------------------------------------
# 2. SECURITY GROUP – Order Tier (port 8082 from ALB only)
# ---------------------------------------------------------------------------

resource "aws_security_group" "order_sg" {
  name        = "${local.env_prefix}-order-sg"
  description = "Order Service - receives from Ext ALB on 8082"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Order Service from External ALB"
    from_port       = 8082
    to_port         = 8082
    protocol        = "tcp"
    security_groups = [aws_security_group.ext_alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-order-sg" }, var.global_tags)
}

# Allow order-service to reach RDS (extends db_sg without touching main.tf)
resource "aws_security_group_rule" "order_to_db" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db_sg.id
  source_security_group_id = aws_security_group.order_sg.id
  description              = "PostgreSQL from Order Service"
}

# ---------------------------------------------------------------------------
# 3. IAM ROLE – Order Service (Secrets Manager + S3 + CloudWatch)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "order_role" {
  name = "${local.env_prefix}-order-role"

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

resource "aws_iam_role_policy_attachment" "order_ssm" {
  role       = aws_iam_role.order_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "order_policy" {
  name = "${local.env_prefix}-order-policy"
  role = aws_iam_role.order_role.id

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
        Sid      = "ReadS3Code"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.testimonials.arn}/*"]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream",
          "logs:PutLogEvents",   "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/cloudkitchen/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "order_profile" {
  name = "${local.env_prefix}-order-profile"
  role = aws_iam_role.order_role.name
}

# ---------------------------------------------------------------------------
# 4. LAUNCH TEMPLATE – Order Service (t3.small, Ubuntu 22.04)
# ---------------------------------------------------------------------------

resource "aws_launch_template" "order_lt" {
  name_prefix   = "${local.env_prefix}-order-lt-"
  image_id      = "ami-0326c8c1e2d6bf78c" # Ubuntu 22.04 LTS ap-south-1
  instance_type = "t3.small"

  iam_instance_profile {
    name = aws_iam_instance_profile.order_profile.name
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }

  vpc_security_group_ids = [aws_security_group.order_sg.id]

  user_data = base64encode(templatefile("${path.module}/userdata/order.sh", {
    s3_bucket        = aws_s3_bucket.testimonials.bucket
    db_secret_arn    = aws_secretsmanager_secret.db.arn
    aws_region       = var.aws_region
    sqs_queue_url    = aws_sqs_queue.orders_queue.url
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = "${local.env_prefix}-order-server" }, var.global_tags)
  }
}

# ---------------------------------------------------------------------------
# 5. TARGET GROUP – Order Service (port 8082)
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "order_tg" {
  name     = "${local.env_prefix}-order-tg"
  port     = 8082
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/api/orders"
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
# 6. AUTO SCALING GROUP – Order Service
# ---------------------------------------------------------------------------

resource "aws_autoscaling_group" "order_asg" {
  name                      = "${local.env_prefix}-order-asg"
  vpc_zone_identifier       = [for s in aws_subnet.private_app : s.id]
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  health_check_type         = "ELB"
  health_check_grace_period = 900 # 15 min – Maven build cold start

  target_group_arns = [aws_lb_target_group.order_tg.arn]

  launch_template {
    id      = aws_launch_template.order_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.env_prefix}-order-server"
    propagate_at_launch = true
  }

  depends_on = [
    aws_nat_gateway.main,
    aws_db_instance.this,
    aws_secretsmanager_secret_version.db,
    aws_s3_object.order_service_code,
  ]
}

# ---------------------------------------------------------------------------
# 7. ALB LISTENER RULE – /api/orders* → Order Service (priority 20)
# ---------------------------------------------------------------------------

resource "aws_lb_listener_rule" "order_rule" {
  listener_arn = aws_lb_listener.ext_http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.order_tg.arn
  }

  condition {
    path_pattern {
      values = ["/api/orders", "/api/orders/*"]
    }
  }
}

# ---------------------------------------------------------------------------
# 8. CLOUDWATCH LOG GROUP – Order Service
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "order" {
  name              = "/cloudkitchen/order"
  retention_in_days = 30
  tags              = var.global_tags
}
