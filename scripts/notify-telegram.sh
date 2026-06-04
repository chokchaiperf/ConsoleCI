#!/bin/bash

set -euo pipefail

TAG_REGEX='^([a-zA-Z]+)-v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]{6})$'
MAX_RETRIES=3
RETRY_DELAY=5

# --- Validate required env vars ---
: "${TELEGRAM_BOT_TOKEN:?ERROR: TELEGRAM_BOT_TOKEN is not set}"
: "${TELEGRAM_CHAT_ID:?ERROR: TELEGRAM_CHAT_ID is not set}"
: "${BUILD_STATUS:?ERROR: BUILD_STATUS is not set}"

# --- Normalize CI-specific variables ---
normalize_ci_vars() {
  if [ "${CIRCLECI:-}" = "true" ]; then
    CI_SOURCE="CircleCI"
    COMMIT_SHA="${CIRCLE_SHA1}"
    REF_NAME="${CIRCLE_TAG:-$CIRCLE_BRANCH}"
    TAG_NAME="${CIRCLE_TAG:-}"
    ACTOR="${CIRCLE_USERNAME}"
    BUILD_URL="${CIRCLE_BUILD_URL}"
    BUILD_NUMBER="${CIRCLE_BUILD_NUM}"
    JOB_NAME="${CIRCLE_JOB}"
  elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    CI_SOURCE="GitHub Actions"
    COMMIT_SHA="${GITHUB_SHA}"
    REF_NAME="${GITHUB_REF_NAME}"
    TAG_NAME=$([ "${GITHUB_REF_TYPE}" = "tag" ] && echo "${GITHUB_REF_NAME}" || echo "")
    ACTOR="${GITHUB_ACTOR}"
    BUILD_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    BUILD_NUMBER="${GITHUB_RUN_NUMBER}"
    JOB_NAME="${GITHUB_JOB}"
  else
    echo "ERROR: Unknown CI environment" >&2
    exit 1
  fi

  if [ -n "${TAG_NAME}" ]; then
    IS_TAG="true"
  else
    IS_TAG="false"
  fi

  SHORT_SHA=$(echo "${COMMIT_SHA}" | cut -c1-7)
  COMMIT_MSG=$(git log -1 --pretty=format:"%s")
  NL=$'\n'
  TIMESTAMP=$(TZ='Asia/Bangkok' date '+%d/%m/%Y %H:%M ICT')
}

# --- Check Obfuscate stamp file ---
check_obfuscate() {
  local stamp
  stamp=$(find . -name "obfuscate.stamp" -not -path "*/obj/*" | head -1)
  if [ -f "${stamp}" ]; then
    OBFUSCATE="true"
  else
    OBFUSCATE="false"
  fi
}

# --- Parse tag and set title/extra ---
parse_tag() {
  EXTRA=""
  APP_VERSION=""

  if [ "${IS_TAG}" = "true" ] && [[ ${TAG_NAME} =~ ${TAG_REGEX} ]]; then
    local slot_key="${BASH_REMATCH[1]}"
    APP_VERSION="v${BASH_REMATCH[2]}"
    local slot_display
    case ${slot_key} in
      sand)    slot_display="Sandbox" ;;
      dev)     slot_display="Development" ;;
      staging) slot_display="Staging" ;;
      rel)     slot_display="Release" ;;
      prod)    slot_display="Production" ;;
      *)       slot_display=$(echo "${slot_key}" | tr '[:lower:]' '[:upper:]') ;;
    esac

    if [ "${BUILD_STATUS}" = "success" ]; then
      TITLE="🚀 <b>Release: ${APP_VERSION}</b>"
    else
      TITLE="❌ <b>Failed: ${APP_VERSION}</b>"
    fi
    EXTRA="${NL}📦 <b>Release Slot</b>  <code>${slot_display}</code>${NL}🏷 <b>App Version</b>  <code>${APP_VERSION}</code>"
  else
    if [ "${BUILD_STATUS}" = "success" ]; then
      TITLE="✅ <b>Success: ${JOB_NAME}</b>"
    else
      TITLE="❌ <b>Failed: ${JOB_NAME}</b>"
    fi
  fi
}

# --- Build message ---
build_message() {
  MESSAGE="${TITLE}${NL}${NL}"
  MESSAGE+="🌿 <b>Branch</b>  <code>${REF_NAME}</code>"
  MESSAGE+="${EXTRA:+$EXTRA}"
  MESSAGE+="${NL}🔒 <b>Obfuscate</b>  <code>${OBFUSCATE}</code>"
  MESSAGE+="${NL}📌 <b>Commit</b>${NL}"
  MESSAGE+="<code>${SHORT_SHA}</code> ${COMMIT_MSG}${NL}${NL}"
  MESSAGE+="👤 <b>Triggered by</b>  ${ACTOR}${NL}"
  MESSAGE+="⚙️ <b>CI</b>  <code>${CI_SOURCE}</code>${NL}"
  MESSAGE+="🔗 <a href=\"${BUILD_URL}\">Build #${BUILD_NUMBER}</a>${NL}"
  MESSAGE+="🕐 <b>Reported at</b>  <code>${TIMESTAMP}</code>"
}

# --- Send to Telegram with retry ---
send_notification() {
  local payload
  payload=$(jq -n \
    --arg chat_id "${TELEGRAM_CHAT_ID}" \
    --arg text "${MESSAGE}" \
    '{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_web_page_preview: true}')

  local attempt=1
  while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
    echo "Sending Telegram notification (attempt ${attempt}/${MAX_RETRIES})..."

    local response
    response=$(curl -s -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "${payload}")

    if echo "${response}" | jq -e '.ok' > /dev/null 2>&1; then
      echo "Telegram notification sent successfully"
      return 0
    fi

    echo "Attempt ${attempt} failed: ${response}" >&2

    if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
      echo "Retrying in ${RETRY_DELAY}s..." >&2
      sleep "${RETRY_DELAY}"
    fi

    attempt=$((attempt + 1))
  done

  echo "ERROR: Failed to send Telegram notification after ${MAX_RETRIES} attempts" >&2
  exit 1
}

# --- Main ---
normalize_ci_vars
check_obfuscate
parse_tag
build_message
send_notification