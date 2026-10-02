#!/bin/bash
set -euo pipefail
cd /opt/feedback
python3.12 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
echo "APP_VERSION=ec2-${DEPLOYMENT_ID}" > version.env
cp feedback.service /etc/systemd/system/feedback.service
systemctl daemon-reload
