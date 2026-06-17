# =============================================================================
# CLOUDKITCHEN – SQS MESSAGING
#
# Queue:  cloudkitchen-orders-queue
#   Producer:  order-service  (publishes OrderPlaced events)
#   Consumer:  ai-recommender (updates real-time demand tracker)
#
# DLQ:    cloudkitchen-orders-dlq
#   Messages that fail 3 receive attempts land here for inspection.
#   CloudWatch alarm fires when DLQ is non-empty.
# =============================================================================

# ── Dead Letter Queue ──────────────────────────────────────────────────────

resource "aws_sqs_queue" "orders_dlq" {
  name                       = "${local.env_prefix}-orders-dlq"
  message_retention_seconds  = 1209600 # 14 days — long enough to diagnose failures
  tags                       = var.global_tags
}

# ── Orders Queue ───────────────────────────────────────────────────────────

resource "aws_sqs_queue" "orders_queue" {
  name                       = "${local.env_prefix}-orders-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600  # 4 days
  receive_wait_time_seconds  = 20      # long-polling — reduces empty receives

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 3
  })

  tags = var.global_tags
}

# ── IAM: order-service can send messages ──────────────────────────────────

resource "aws_iam_role_policy" "order_sqs_policy" {
  name = "${local.env_prefix}-order-sqs-policy"
  role = aws_iam_role.order_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "SendOrderEvents"
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.orders_queue.arn
    }]
  })
}

# ── IAM: ai-recommender can receive and delete messages ───────────────────

resource "aws_iam_role_policy" "ai_sqs_policy" {
  name = "${local.env_prefix}-ai-sqs-policy"
  role = aws_iam_role.ai_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ConsumeOrderEvents"
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueUrl",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ]
      Resource = aws_sqs_queue.orders_queue.arn
    }]
  })
}

# ── CloudWatch Alarm: DLQ non-empty = processing failure ──────────────────

resource "aws_cloudwatch_metric_alarm" "orders_dlq_depth" {
  alarm_name          = "${local.env_prefix}-orders-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Orders DLQ has messages — order events failed processing 3 times"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.orders_dlq.name
  }

  tags = var.global_tags
}
