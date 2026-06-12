#!/bin/bash
# =============================================================================
# CLOUDKITCHEN – AI TIER USER DATA
# Runs on every new AI ASG instance (Ubuntu 22.04 LTS)
# =============================================================================

set -ex
exec > /var/log/userdata-ai.log 2>&1
echo "[$(date)] Starting AI Tier setup..."

# 1. Install dependencies
apt-get update -y
apt-get install -y python3.10 python3.10-venv python3-pip unzip awscli curl

# Install CloudWatch Agent
curl -fsSL https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o /tmp/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

# 2. Download AI code from S3
cd /opt
echo "[$(date)] Downloading AI Recommender from S3..."
aws s3 cp s3://${s3_bucket}/ai_recommender.zip /opt/ai_recommender.zip
unzip /opt/ai_recommender.zip -d /opt/ai_recommender
cd /opt/ai_recommender

# 3. Setup Python Virtual Environment
echo "[$(date)] Setting up Python virtual environment..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# 4. Create systemd service for FastAPI
echo "[$(date)] Creating systemd service..."
cat > /etc/systemd/system/airecommender.service << SVCEOF
[Unit]
Description=CloudKitchen AI Recommender FastAPI
After=network.target

[Service]
User=root
WorkingDirectory=/opt/ai_recommender
Environment="PATH=/opt/ai_recommender/venv/bin"
ExecStart=/opt/ai_recommender/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

# 5. Enable and start the service
systemctl daemon-reload
systemctl enable airecommender
systemctl start airecommender

echo "[$(date)] AI Tier setup COMPLETE."
