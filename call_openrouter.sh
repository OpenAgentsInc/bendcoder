#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="$DIR/.env.openrouter"

if [ -n "$OPENROUTER_API_KEY" ]; then
  KEY="$OPENROUTER_API_KEY"
elif [ -f "$ENV_FILE" ]; then
  KEY="$(grep -v '^#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | head -n 1 | tr -d '\r\n')"
fi

if [ -z "$KEY" ] || [ "$KEY" = "YOUR_OPENROUTER_API_KEY" ]; then
  echo "Error: No valid OpenRouter API key found."
  echo "Please set OPENROUTER_API_KEY environment variable or put your key in $ENV_FILE"
  exit 1
fi

MODEL="${OPENROUTER_MODEL:-openai/gpt-oss-120b:nitro}"
BACKUP_MODEL="${OPENROUTER_BACKUP_MODEL:-deepseek/deepseek-v4-flash-0731:free}"

echo "Sending request to OpenRouter ($MODEL, backup: $BACKUP_MODEL)..."

curl -s -X POST https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://github.com/OpenAgentsInc/bendcoder" \
  -H "X-Title: Bendcoder Agent" \
  -d "{
    \"model\": \"$MODEL\",
    \"models\": [\"$MODEL\", \"$BACKUP_MODEL\"],
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a succinct systems coding assistant.\"},
      {\"role\": \"user\", \"content\": \"Write a minimal 1-line hello world function in C.\"}
    ]
  }" | jq . 2>/dev/null || cat
echo ""
