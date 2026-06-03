#!/bin/bash
# scripts/notify-telegram.sh
# Shared Telegram notification script — works with CircleCI and GitHub Actions
#
# Required env vars:
#   TELEGRAM_BOT_TOKEN  — bot token
#   TELEGRAM_CHAT_ID    — target chat/group ID
#   BUILD_STATUS        — "success" | "failed"

set -e

TAG_REGEX='^([a-zA-Z]+)-v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]{6})$'

# --- Normalize CI-specific variables ---
if [ "$CIRCLECI" = "true" ]; then
  CI_SOURCE="CircleCI"
  COMMIT_SHA="$CIRCLE_SHA1"
  REF_NAME="${CIRCLE_TAG:-$CIRCLE_BRANCH}"
  TAG_NAME="$CIRCLE_TAG"
  IS_TAG=$([ -n "$CIRCLE_TAG" ] && echo "true" || echo "false")
  ACTOR="$CIRCLE_USERNAME"
  BUILD_URL="$CIRCLE_BUILD_URL"
  BUILD_NUMBER="$CIRCLE_BUILD_NUM"
  JOB_NAME="$CIRCLE_JOB"
elif [ "$GITHUB_ACTIONS" = "true" ]; then
  CI_SOURCE="GitHub Actions"
  COMMIT_SHA="$GITHUB_SHA"
  REF_NAME="$GITHUB_REF_NAME"
  TAG_NAME=$([ "$GITHUB_REF_TYPE" = "tag" ] && echo "$GITHUB_REF_NAME" || echo "")
  IS_TAG=$([ "$GITHUB_REF_TYPE" = "tag" ] && echo "true" || echo "false")
  ACTOR="$GITHUB_ACTOR"
  BUILD_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  BUILD_NUMBER="$GITHUB_RUN_NUMBER"
  JOB_NAME="$GITHUB_JOB"
else
  echo "ERROR: Unknown CI environment"
  exit 1
fi

SHORT_SHA=$(echo "$COMMIT_SHA" | cut -c1-7)
COMMIT_MSG=$(git log -1 --pretty=format:"%s")
NL=$'\n'
TIMESTAMP=$(TZ='Asia/Bangkok' date '+%d/%m/%Y %H:%M ICT')

# --- Obfuscate stamp file ---
STAMP=$(find . -name "obfuscate.stamp" -not -path "*/obj/*" | head -1)
if [ -f "$STAMP" ]; then
  OBFUSCATE="true"
else
  OBFUSCATE="false"
fi

# --- Parse tag ---
if [ "$IS_TAG" = "true" ] && [[ $TAG_NAME =~ $TAG_REGEX ]]; then
  SLOT_KEY="${BASH_REMATCH[1]}"
  APP_VERSION="v${BASH_REMATCH[2]}"
  case $SLOT_KEY in
    sand)    SLOT_DISPLAY="Sandbox" ;;
    dev)     SLOT_DISPLAY="Development" ;;
    staging) SLOT_DISPLAY="Staging" ;;
    rel)     SLOT_DISPLAY="Release" ;;
    prod)    SLOT_DISPLAY="Production" ;;
    *)       SLOT_DISPLAY=$(echo "$SLOT_KEY" | tr '[:lower:]' '[:upper:]') ;;
  esac

  if [ "$BUILD_STATUS" = "success" ]; then
    TITLE="🚀 <b>Release: $APP_VERSION</b>"
  else
    TITLE="❌ <b>Failed: $APP_VERSION</b>"
  fi
  EXTRA="${NL}📦 <b>Release Slot</b>  <code>$SLOT_DISPLAY</code>${NL}🏷 <b>App Version</b>  <code>$APP_VERSION</code>"
else
  if [ "$BUILD_STATUS" = "success" ]; then
    TITLE="✅ <b>Success: $JOB_NAME</b>"
  else
    TITLE="❌ <b>Failed: $JOB_NAME</b>"
  fi
  EXTRA=""
fi

# --- Build message ---
MESSAGE="${TITLE}${NL}${NL}"
MESSAGE+="🌿 <b>Branch</b>  <code>${REF_NAME}</code>"
MESSAGE+="${EXTRA:+$EXTRA}"
MESSAGE+="${NL}🔒 <b>Obfuscate</b>  <code>$OBFUSCATE</code>"
MESSAGE+="${NL}📌 <b>Commit</b>${NL}"
MESSAGE+="<code>$SHORT_SHA</code> $COMMIT_MSG${NL}${NL}"
MESSAGE+="👤 <b>Triggered by</b>  $ACTOR${NL}"
MESSAGE+="⚙️ <b>CI</b>  <code>$CI_SOURCE</code>${NL}"
MESSAGE+="🔗 <a href=\"$BUILD_URL\">Build #$BUILD_NUMBER</a>${NL}"
MESSAGE+="🕐 <b>Reported at</b>  <code>$TIMESTAMP</code>"

# --- Send to Telegram ---
jq -n \
  --arg chat_id "$TELEGRAM_CHAT_ID" \
  --arg text "$MESSAGE" \
  '{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_web_page_preview: true}' | \
curl -s -o /dev/null -X POST \
  "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
  -H "Content-Type: application/json" \
  -d @-
