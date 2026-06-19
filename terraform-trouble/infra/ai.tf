# =============================================================================
# AI MICROSERVICE INFRASTRUCTURE
# =============================================================================

# Zip the local AI code
data "archive_file" "ai_recommender_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../services/ai-recommender"
  output_path = "${path.module}/ai_recommender.zip"
}

# Upload to S3 (kept for reference / hash trigger; instances now run the ECR image)
resource "aws_s3_object" "ai_recommender_code" {
  bucket = aws_s3_bucket.testimonials.id
  key    = "deployments/ai_recommender.zip"
  source = data.archive_file.ai_recommender_zip.output_path
  etag   = filemd5(data.archive_file.ai_recommender_zip.output_path)
}

# ─────────────────────────────────────────────────────────────────────────────
# PREBUILT AI IMAGE → ECR  (built locally with Docker, pushed to ECR)
#
# Builds the AI recommender image on the machine running `terraform apply` and
# pushes it to ECR. The EC2 instance then just `docker pull`s it, so it boots in
# ~3 min instead of a 20-min on-boot pip install of torch/sentence-transformers.
#
# PREREQUISITE: Docker must be installed and running on the machine that runs
# `terraform apply`. The build runs in parallel with the rest of the infra, so
# by the time apply finishes the image is in ECR and the AI instance comes up
# within ~3 minutes. The CPU-only torch Dockerfile keeps the image ~2.5 GB.
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "ai_image_build" {
  triggers = {
    src_hash  = data.archive_file.ai_recommender_zip.output_md5
    image_uri = "${aws_ecr_repository.ai_repo.repository_url}:latest"
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../services/ai-recommender"
    interpreter = ["bash", "-c"]
    command     = <<-CMD
      set -e
      REGISTRY="${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
      IMAGE="${aws_ecr_repository.ai_repo.repository_url}:latest"
      if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker is not running. Install/start Docker and re-run terraform apply." >&2
        exit 1
      fi
      echo "Logging in to ECR ($REGISTRY)..."
      aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin "$REGISTRY"
      echo "Building AI image (~10-15 min; runs in parallel with the rest of the apply)..."
      docker build -t "$IMAGE" .
      echo "Pushing to ECR..."
      docker push "$IMAGE"
      echo "AI image ready: $IMAGE"
    CMD
  }
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
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ai_ssm" {
  role       = aws_iam_role.ai_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets the AI instance pull the prebuilt container image from ECR (ai_repo)
resource "aws_iam_role_policy_attachment" "ai_ecr_read" {
  role       = aws_iam_role.ai_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
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
  instance_type = "t3.medium"             # 4 GB RAM: sufficient for llama3.2:1b (~620 MB) + FastAPI stack (~1.4 GB)

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
    ai_image_uri  = "${aws_ecr_repository.ai_repo.repository_url}:latest"
    ecr_registry  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
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
  name                      = "${local.env_prefix}-ai-asg"
  vpc_zone_identifier       = [for s in aws_subnet.private_app : s.id]
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  health_check_type         = "ELB" # replace instances whose /api/health fails — not just dead EC2 (prevents a dead container lingering as "healthy")
  health_check_grace_period = 600   # ~10 min: Docker install + image pull (no on-boot pip build anymore)

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

  # Don't launch instances until the image is built and pushed to ECR
  depends_on = [null_resource.ai_image_build]
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
      values = ["/api/recommend*", "/api/update_user_preferences*", "/api/demand*"]
    }
  }
}
