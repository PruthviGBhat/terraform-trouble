# =============================================================================
# AI MICROSERVICE INFRASTRUCTURE
# =============================================================================

# Zip the local AI code
data "archive_file" "ai_recommender_zip" {
  type        = "zip"
  source_dir  = "${path.module}/cloudkitchen-aws/ai-recommender"
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
  image_id      = var.app_ami_id
  instance_type = "t3.medium" # Requires more RAM for AI models

  iam_instance_profile {
    name = aws_iam_instance_profile.ai_profile.name
  }

  vpc_security_group_ids = [aws_security_group.ai_sg.id]

  user_data = base64encode(templatefile("${path.module}/userdata/ai.sh", {
    s3_bucket = aws_s3_bucket.testimonials.bucket
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

  target_group_arns = [aws_lb_target_group.ai_tg.arn]

  launch_template {
    id      = aws_launch_template.ai_lt.id
    version = "$Latest"
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
    path                = "/docs" # FastAPI default docs endpoint
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
