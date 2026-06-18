#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – AI TIER USER DATA
# Runs on every new AI ASG instance (Ubuntu 22.04 LTS, t3.medium)
# LLM: Mistral-7B-Instruct via HuggingFace Inference API (no local model needed)
# =============================================================================

set -ex
exec > /var/log/userdata-ai.log 2>&1
echo "[$(date)] Starting AI Tier setup..."

# ── 1. Network + system packages ──────────────────────────────────────────────
until ping -c 1 archive.ubuntu.com &>/dev/null; do
  echo "Network not ready — retrying in 5s..."; sleep 5
done

apt-get update -y
apt-get install -y python3 python3-venv python3-pip unzip awscli curl

# CloudWatch Agent (for log shipping)
curl -fsSL https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb \
  -o /tmp/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

# ── 2. Download AI service code from S3 ───────────────────────────────────────
echo "[$(date)] Downloading AI Recommender code from S3..."
aws s3 cp s3://${s3_bucket}/deployments/ai_recommender.zip /opt/ai_recommender.zip
unzip -q /opt/ai_recommender.zip -d /opt/ai_recommender
cd /opt/ai_recommender

# ── 3. Python virtual environment + dependencies ───────────────────────────────
echo "[$(date)] Installing Python dependencies..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip --quiet
pip install --no-cache-dir -r requirements.txt --quiet

# ── 4. FastAPI systemd service ────────────────────────────────────────────────
echo "[$(date)] Creating FastAPI systemd service..."
cat > /etc/systemd/system/airecommender.service << SVCEOF
[Unit]
Description=CloudKitchen AI Recommender (FastAPI + LangChain + HuggingFace API)
After=network.target

[Service]
User=root
WorkingDirectory=/opt/ai_recommender
Environment="PATH=/opt/ai_recommender/venv/bin"
Environment="SQS_ORDERS_QUEUE_URL=${sqs_queue_url}"
Environment="AWS_REGION=${aws_region}"
Environment="HUGGINGFACEHUB_API_TOKEN=${hf_api_token}"
Environment="HF_MODEL=mistralai/Mistral-7B-Instruct-v0.3"
ExecStart=/opt/ai_recommender/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable airecommender
systemctl start airecommender

echo "[$(date)] AI Tier setup COMPLETE."
