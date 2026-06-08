# =============================================================================
# CLOUDKITCHEN – TERRAFORM OUTPUTS
# =============================================================================

# ── Networking ────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (Web Tier)"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_app_subnet_ids" {
  description = "Private App Tier subnet IDs"
  value       = [for s in aws_subnet.private_app : s.id]
}

output "private_db_subnet_ids" {
  description = "Private DB Tier subnet IDs"
  value       = [for s in aws_subnet.private_db : s.id]
}

# ── Load Balancers ────────────────────────────────────────────────────────

output "external_alb_dns" {
  description = "Public URL of the External ALB – API Entrypoint"
  value       = "http://${aws_lb.external.dns_name}"
}

# ── Database ──────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (private – accessible from App Tier only)"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  description = "RDS PostgreSQL port"
  value       = aws_db_instance.this.port
}

output "rds_db_name" {
  description = "Database name"
  value       = aws_db_instance.this.db_name
}

# ── Secrets ───────────────────────────────────────────────────────────────

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  description = "Name of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.db.name
}

# ── Security Groups ───────────────────────────────────────────────────────

output "ext_alb_sg_id" {
  description = "External ALB security group ID"
  value       = aws_security_group.ext_alb_sg.id
}

output "app_sg_id" {
  description = "App Tier security group ID"
  value       = aws_security_group.app_sg.id
}

output "db_sg_id" {
  description = "DB Tier security group ID"
  value       = aws_security_group.db_sg.id
}

# ── S3 ────────────────────────────────────────────────────────────────────

output "backup_bucket_name" {
  description = "S3 bucket name for DB backups"
  value       = aws_s3_bucket.backups.bucket
}

# ── Quick Reference ───────────────────────────────────────────────────────

output "quick_reference" {
  description = "Copy-paste commands for common admin tasks"
  value       = <<-EOT

    ═══════════════════════════════════════════════════════
    CLOUDKITCHEN – QUICK REFERENCE
    ═══════════════════════════════════════════════════════

    🌐 Application URL (CloudFront):
       https://${aws_cloudfront_distribution.cdn.domain_name}

    🔗 API Base URL:
       https://${aws_cloudfront_distribution.cdn.domain_name}/api

    📋 App Tier logs (on App instance via SSM):
       sudo journalctl -u cloudkitchen -f
       sudo tail -f /var/log/cloudkitchen/app.log

    🗄️  Connect to RDS (from App instance):
       PGPASSWORD=$(aws secretsmanager get-secret-value \
         --secret-id ${aws_secretsmanager_secret.db.name} \
         --query SecretString --output text | jq -r .password) \
       psql -h ${aws_db_instance.this.address} -U postgres -d cloudkitchen

    🔍 Test App Tier health (via ALB):
       curl http://${aws_lb.external.dns_name}/api/categories

    ═══════════════════════════════════════════════════════
  EOT
}

output "cloudfront_url" {
  description = "CloudFront Global CDN URL"
  value       = aws_cloudfront_distribution.cdn.domain_name
}

output "api_gateway_url" {
  description = "API Gateway URL for Video Testimonials Presign"
  value       = aws_apigatewayv2_stage.default.invoke_url
}