#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: notify-telegram.sh <version>}"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "❌ ERROR: TELEGRAM_BOT_TOKEN environment variable is not set"
  exit 1
fi

if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "❌ ERROR: TELEGRAM_CHAT_ID environment variable is not set"
  exit 1
fi

RELEASE_URL="https://github.com/TableProApp/TablePro/releases/tag/v${VERSION}"
NOTES=$(cat release_notes.md 2>/dev/null || echo "Bug fixes and improvements")

ESCAPED=$(echo "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

FORMATTED=$(echo "$ESCAPED" | sed -E \
  -e 's/^### (.+)$/<b>\1<\/b>/' \
  -e 's/^- /• /' \
  -e 's/`([^`]+)`/<code>\1<\/code>/g' \
  -e '/^[[:space:]]*$/d')

MESSAGE_LIMIT=4096
TRUNCATION_NOTICE="• Read the rest in the full release notes."

build_message() {
  printf '<b>TablePro v%s Released</b>\n\n%s\n\n<a href="%s">View Release</a>' "$VERSION" "$1" "$RELEASE_URL"
}

message_length() {
  printf '%s' "$1" | wc -m | tr -d ' '
}

TEXT=$(build_message "$FORMATTED")

# Telegram rejects a message over MESSAGE_LIMIT outright, so keep whole entries
# until the budget runs out and point at the release for the remainder.
if [ "$(message_length "$TEXT")" -gt "$MESSAGE_LIMIT" ]; then
  OVERHEAD=$(( $(message_length "$TEXT") - $(message_length "$FORMATTED") ))
  BUDGET=$(( MESSAGE_LIMIT - OVERHEAD - ${#TRUNCATION_NOTICE} - 1 ))
  KEPT=$(printf '%s\n' "$FORMATTED" | awk -v budget="$BUDGET" '
    { if (used + length($0) + 1 > budget) exit
      used += length($0) + 1
      print }')
  FORMATTED=$(printf '%s\n%s' "$KEPT" "$TRUNCATION_NOTICE")
  TEXT=$(build_message "$FORMATTED")
  echo "Release notes exceeded ${MESSAGE_LIMIT} characters, trimmed to $(message_length "$TEXT")"
fi

PAYLOAD=$(jq -n \
  --arg chat_id "$TELEGRAM_CHAT_ID" \
  --arg text "$TEXT" \
  --arg topic_id "${TELEGRAM_TOPIC_ID:-}" \
  '{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_web_page_preview: true}
  + (if $topic_id != "" then {message_thread_id: ($topic_id | tonumber)} else {} end)')

RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

if echo "$RESPONSE" | jq -e '.ok == true' > /dev/null; then
  echo "Telegram notification sent for v${VERSION}"
else
  echo "Telegram API rejected the message:"
  echo "$RESPONSE" | jq .
  exit 1
fi
