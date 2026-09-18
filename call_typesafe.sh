#!/usr/bin/env bash
set -e

# Directory of this script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="$DIR/.env.typesafe"

# Read key from TYPESAFE_API_KEY environment variable if set, otherwise from .env.typesafe
if [ -n "$TYPESAFE_API_KEY" ]; then
  KEY="$TYPESAFE_API_KEY"
elif [ -f "$ENV_FILE" ]; then
  KEY="$(grep -v '^#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | head -n 1 | tr -d '\r\n')"
fi

if [ -z "$KEY" ] || [ "$KEY" = "YOUR_TYPESAFE_API_KEY" ]; then
  echo "Error: No valid TypeSafe API key found."
  echo "Please set TYPESAFE_API_KEY environment variable or put your key in $ENV_FILE"
  exit 1
fi

echo "Sending request to https://api.typesafe.ai/v1/systemone ..."

curl -s -X POST https://api.typesafe.ai/v1/systemone \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "state": "Hi, I have been trying to connect my Stripe account for 3 days and it keeps failing. I am losing sales. Please help ASAP.",
    "model": "jev-latest",
    "questions": {
      "department": {
        "type": "choice",
        "instructions": "Which team should handle this?",
        "criteria": {
          "billing": "Payment or subscription issues",
          "technical": "Bugs or integration problems",
          "sales": "Pricing or account questions"
        }
      },
      "frustration": {
        "type": "score",
        "instructions": "How frustrated the customer appears",
        "criteria": [
          "Calm, just stating facts",
          "Frustrated but civil",
          "Very angry, strong language"
        ]
      },
      "is_urgent": {
        "type": "noul",
        "instructions": "The message conveys urgency or time-sensitivity"
      }
    }
  }' | jq . 2>/dev/null || cat
echo ""
