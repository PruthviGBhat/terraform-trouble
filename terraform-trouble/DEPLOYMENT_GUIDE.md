# CloudKitchen — Deployment Guide

**One command to bring it all up. One command to tear it all down.**

`terraform apply` inside `infra/` deploys every resource — VPC, ALB, EC2 ASGs, RDS, Cognito, S3, CloudFront, Lambda, API Gateway, ECR, the AI service, and the React frontend. No manual steps after that.

---

## Project Structure

```
terraform-cloudkitchen/
├── infra/                   ← all Terraform lives here
│   ├── bootstrap/           ← one-time S3 state backend setup
│   ├── terraform.tfvars     ← your personal settings (gitignored)
│   ├── main.tf              ← core VPC, networking, ALB, ASG, RDS
│   ├── auth.tf              ← auth-service ASG + Cognito user pools
│   ├── order.tf             ← order-service ASG
│   ├── ai.tf                ← AI recommender EC2 + EBS
│   ├── ecr.tf               ← ECR repositories
│   ├── addons.tf            ← CloudFront, Lambda, API Gateway, frontend deploy
│   ├── state-backend.tf     ← S3 backend config (toggle remote state)
│   ├── backend.tf           ← active backend declaration
│   ├── variables.tf
│   └── outputs.tf
└── services/                ← all application code lives here
    ├── frontend/            ← React app (auto-built by terraform apply)
    ├── menu-service/        ← Spring Boot, port 8080 (Flyway owner)
    ├── order-service/       ← Spring Boot, port 8082
    ├── auth-service/        ← Spring Boot, port 8081
    └── ai-recommender/      ← FastAPI + flan-t5-small + ChromaDB
```

---

## Phase 0 — Prerequisites

### Software to install

| Tool | Version | Download |
|------|---------|----------|
| Terraform | ≥ 1.0 | https://developer.hashicorp.com/terraform/downloads |
| AWS CLI v2 | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Node.js | ≥ 18 | https://nodejs.org/ (required for the auto-build step) |
| Git | any | https://git-scm.com/downloads |

### Configure AWS credentials

```bash
aws configure
# Enter: Access Key, Secret Key, region (ap-south-1), output (json)
```

### Create an EC2 Key Pair

1. AWS Console → EC2 → Key Pairs → Create key pair
2. Name: e.g. `my-cloudkitchen-key` (RSA, .pem format)
3. Download and keep the `.pem` file safe

---

## Phase 1 — Bootstrap (one-time only)

Creates the S3 bucket + DynamoDB table that store Terraform state safely.

```bash
cd infra/bootstrap
terraform init
terraform apply -auto-approve
```

Note the output `state_bucket_name` — it looks like `cloudkitchen-tfstate-123456789012`.

Then open `infra/backend.tf` and confirm the bucket name matches your account ID (it's pre-filled — just verify the 12-digit number is yours).

Finally, migrate state into S3:

```bash
cd ..           # back to infra/
terraform init -migrate-state
# Type "yes" when prompted
```

> Skip this phase entirely if you want local state (fine for dev). In that case, comment out the `terraform { backend "s3" {...} }` block in `infra/backend.tf`.

---

## Phase 2 — Configure Your Settings

```bash
# inside infra/
cp terraform.tfvars.example terraform.tfvars   # if an example exists, otherwise edit directly
```

Open `infra/terraform.tfvars` and set:

```hcl
aws_region  = "ap-south-1"           # must match your key pair region
key_name    = "my-cloudkitchen-key"  # exact name from Phase 0
admin_email = "you@example.com"      # for SNS CloudWatch alerts
web_ami_id  = "ami-0xxxxxxxxxxxxxxx" # Ubuntu 22.04 AMI in your region
app_ami_id  = "ami-0xxxxxxxxxxxxxxx" # same AMI is fine for app tier
```

To find the latest Ubuntu 22.04 AMI in `ap-south-1`:

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text \
  --region ap-south-1
```

---

## Phase 3 — Deploy Everything

```bash
cd infra/
terraform validate   # quick syntax check
terraform apply      # review the plan, then type "yes"
```

This single command:

1. Creates the VPC, subnets, NAT gateways, security groups
2. Launches the ALB with path-based routing rules
3. Creates RDS PostgreSQL and stores credentials in Secrets Manager
4. Creates Cognito user pools (customers + restaurants)
5. Launches four EC2 Auto Scaling Groups (menu, order, auth, AI)
6. Uploads each service's source zip to S3; EC2 userdata downloads and builds it
7. Builds the React frontend (`npm install && npm run build`) and syncs it to S3
8. Deploys CloudFront CDN pointing to the S3 frontend bucket
9. Deploys the Lambda + API Gateway for video testimonial presigned URLs
10. Invalidates the CloudFront cache

**Total time: ~25-35 minutes**

| Stage | Time |
|-------|------|
| Terraform provisioning (AWS resources) | ~10-15 min |
| EC2 Maven builds + DB migration | ~15-20 min |
| Frontend build (happens in parallel) | ~2-3 min |

> The React app appears immediately via CloudFront. Backend API calls will return 502 until the Spring Boot services finish starting — this is normal. Wait 15-20 min after `terraform apply` completes, then test.

---

## Phase 4 — Verify the Deployment

Terraform prints output values when apply finishes. Look for:

```
cloudfront_url         = "https://dxxxxxxxxxxxx.cloudfront.net"
external_alb_dns       = "cloudkitchen-ext-alb-xxxx.ap-south-1.elb.amazonaws.com"
api_gateway_url        = "https://xxxxxxxxxx.execute-api.ap-south-1.amazonaws.com/prod"
```

### Quick health checks

```bash
# Frontend (via CloudFront)
curl -I https://<cloudfront_url>

# Menu service
curl http://<external_alb_dns>/api/categories

# Auth service (Cognito registration)
curl -X POST http://<external_alb_dns>/auth/api/users/register \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","email":"test@test.com","password":"Test1234!"}'

# AI recommendations
curl -X POST http://<external_alb_dns>/api/recommend_quick \
  -H "Content-Type: application/json" \
  -d '{"query":"something spicy","preferences":["vegetarian"],"allergies":[],"top_k":3}'

# AI demand forecasting
curl -X POST http://<external_alb_dns>/api/recommend_forecast \
  -H "Content-Type: application/json" \
  -d '{"items":[{"id":"1","name":"Paneer Butter Masala","kitchen":"North Indian Kitchen","inventory":45,"predicted_demand":60}]}'
```

### ALB Path Routing Reference

| Path | Service | Port | Notes |
|------|---------|------|-------|
| `/auth/*` | auth-service | 8081 | Cognito-backed JWT auth |
| `/api/orders*` | order-service | 8082 | PostgreSQL, Flyway disabled |
| `/api/recommend*` | ai-recommender | 8000 | FastAPI + flan-t5-small |
| `/*` (default) | menu-service | 8080 | Flyway owner |

### SNS Email Subscription

Check your inbox for an AWS SNS confirmation email. Click "Confirm subscription" to start receiving CloudWatch alerts.

---

## Phase 5 — Teardown (Avoid AWS Charges)

```bash
# Step 1 — destroy all main infrastructure
cd infra/
terraform destroy

# Step 2 — destroy the state backend (only if you won't use this project again)
cd infra/bootstrap/
terraform destroy
```

`terraform destroy` removes: VPC, ALBs, EC2 ASGs, RDS, Cognito pools, S3 buckets (including frontend), CloudFront, Lambda, API Gateway, ECR repos, Secrets Manager secrets, CloudWatch alarms, SNS topic.

> The bootstrap bucket and DynamoDB table (Phase 1) survive `terraform destroy` in the main `infra/` directory — they are in a separate state. Destroy them separately with the step above only when you're fully done.

---

## Troubleshooting

### API returns 502 right after deploy

Normal. The Spring Boot services take ~15 min to finish Maven build and Flyway migrations. Wait and retry.

### AI service returns 503

The flan-t5-small model downloads on first start (~250 MB). Give the AI instance ~20 min on first boot. The frontend dashboard shows a friendly "warming up" message in the meantime.

### Frontend shows old version after re-deploy

CloudFront CDN is automatically invalidated during `terraform apply`. If you still see stale content, do a hard refresh (Ctrl+Shift+R) or wait ~5 min for edge cache propagation.

### `terraform apply` fails on frontend build

The `null_resource.deploy_frontend` step requires Node.js ≥ 18 to be on your PATH. Verify with `node --version` and `npm --version` before running apply.

### Need to rebuild frontend only (without full apply)

```bash
cd services/frontend
npm install && npm run build
aws s3 sync build/ s3://cloudkitchen-frontend-<ACCOUNT_ID> --delete
aws cloudfront create-invalidation --distribution-id <CF_ID> --paths "/*"
```
