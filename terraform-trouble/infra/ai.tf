# =============================================================================
# AI MICROSERVICE INFRASTRUCTURE
# =============================================================================

# Zip the local AI code
data "archive_file" "ai_recommender_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../services/ai-recommender"
  output_path = "${path.module}/ai_recommender.zip"
}

# Upload to S3 (Using the existing testimonials bucket from addons.tf)
resource "aws_s3_object" "ai_recommender_code" {
  bucket = aws_s3_bucket.testimonials.id
  key    = "deployments/ai_recommender.zip"
  source = data.archive_file.ai_recommender_zip.output_path
  etag   = filemd5(data.archive_file.ai_recommender_zip.output_path)
}

# Security Group for AI Server
resource "aws_security_group" "ai_sg" {
  name        = "${local.env_prefix}-ai-sg"
  description = "Security group for AI servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow 8000 from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.ext_alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-ai-sg" }, var.global_tags)
}

# IAM Role for AI Server
resource "aws_iam_role" "ai_role" {
  name = "${local.env_prefix}-ai-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ai_ssm" {
  role       = aws_iam_role.ai_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ai_s3_policy" {
  name = "${local.env_prefix}-ai-s3-policy"
  role = aws_iam_role.ai_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.testimonials.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ai_profile" {
  name = "${local.env_prefix}-ai-profile"
  role = aws_iam_role.ai_role.name
}

# AI Launch Template
resource "aws_launch_template" "ai_lt" {
  name_prefix   = "${local.env_prefix}-ai-lt-"
  image_id      = "ami-0326c8c1e2d6bf78c" # Ubuntu 22.04 LTS for ML package compatibility
  instance_type = "t3.medium" # 4 GB RAM: sufficient for llama3.2:1b (~620 MB) + FastAPI stack (~1.4 GB)

  iam_instance_profile {
    name = aws_iam_instance_profile.ai_profile.name
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }

  vpc_security_group_ids = [aws_security_group.ai_sg.id]

  user_data = base64encode(templatefile("${path.module}/userdata/ai.sh", {
    s3_bucket     = aws_s3_bucket.testimonials.bucket
    sqs_queue_url = aws_sqs_queue.orders_queue.url
    aws_region    = var.aws_region
    hf_api_token  = var.hf_api_token
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = "${local.env_prefix}-ai-server" }, var.global_tags)
  }
}

# AI Auto Scaling Group
resource "aws_autoscaling_group" "ai_asg" {
  name                = "${local.env_prefix}-ai-asg"
  vpc_zone_identifier = [for s in aws_subnet.private_app : s.id]
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  health_check_grace_period = 1200 # Allow 20 min: apt + pip install (sentence-transformers, chromadb)

  target_group_arns = [aws_lb_target_group.ai_tg.arn]

  launch_template {
    id      = aws_launch_template.ai_lt.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.env_prefix}-ai-server"
    propagate_at_launch = true
  }
}

# AI Target Group
resource "aws_lb_target_group" "ai_tg" {
  name     = "${local.env_prefix}-ai-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/api/health"
    port                = "traffic-port"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }

  tags = var.global_tags
}

# ALB Listener Rule (Routes /api/recommend and /api/update_user_preferences to AI TG)
resource "aws_lb_listener_rule" "ai_rule" {
  listener_arn = aws_lb_listener.ext_http.arn
  priority     = 50 # Ensure it evaluates before default routing

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_tg.arn
  }

  condition {
    path_pattern {
      values = ["/api/recommend*", "/api/update_user_preferences*"]
    }
  }
}
