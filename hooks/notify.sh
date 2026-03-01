#!/bin/bash
NTFY_TOPIC="${NTFY_TOPIC:-my-claude-topic}"
DEBOUNCE_SECONDS=${NTFY_DEBOUNCE:-300}  # 기본 5분
LAST_FILE="/tmp/ntfy-last-notify"

LAST=$(cat "$LAST_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s)

if [ $((NOW - LAST)) -ge "$DEBOUNCE_SECONDS" ]; then
  curl -s -d "Claude가 입력을 기다리고 있습니다" "ntfy.sh/${NTFY_TOPIC}" || \
    (sleep 5 && curl -s -d "Claude가 입력을 기다리고 있습니다" "ntfy.sh/${NTFY_TOPIC}")
  echo "$NOW" > "$LAST_FILE"
fi
