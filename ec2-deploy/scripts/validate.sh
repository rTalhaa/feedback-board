#!/bin/bash
# Fails the deployment (and triggers auto-rollback) if the app doesn't answer within ~60s.
for _ in $(seq 30); do
  curl -sf http://localhost:8080/health && exit 0
  sleep 2
done
exit 1
