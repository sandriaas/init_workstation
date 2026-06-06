#!/bin/bash

LOG_FILE="/data/logs/health-check.log"
mkdir -p /data/logs

check_service() {
    local name=$1
    local url=$2
    local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
    if [ "$status" = "200" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name: OK ($status)" >> "$LOG_FILE"
        return 0
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name: FAIL ($status)" >> "$LOG_FILE"
        return 1
    fi
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Health check started" >> "$LOG_FILE"

while true; do
    check_service "multica" "http://multica-backend:8080/healthz"
    check_service "hermes" "http://hermes:8642/health"
    check_service "paperclip" "http://code_paperclip:3100/api/health"
    check_service "nginx" "http://localhost:80/runner/health"
    sleep 60
done
