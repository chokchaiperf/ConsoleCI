#!/bin/bash
# scripts/notify-telegram.sh
# Shared Telegram notification script — works with CircleCI and GitHub Actions
#
# Required env vars:
#   TELEGRAM_BOT_TOKEN      — bot token
#   TELEGRAM_CHAT_ID        — target chat/group ID
#   BUILD_STATUS            — "success" | "failed"
#
# Optional env vars:
#   PLATFORM                — "iOS" | "Android" | "iOS or Android"
#   APP_NAME                — app display name. ถ้าไม่ส่งมาจาก CI จะอ่านค่า property
#                             $(ApplicationTitle) ตรงจาก .csproj ให้อัตโนมัติด้วย
#                             `dotnet build -getProperty` (ไม่ผ่าน build log ใดๆ —
#                             ตั้งชื่อ property ให้ตรงกับ .NET MAUI ไว้ เพื่อให้
#                             migrate เข้า MAUI project จริงได้โดยไม่ต้องแก้ pipeline)
#   PROJECT_PATH            — path ไปยัง .csproj ที่จะอ่าน ApplicationTitle
#                             (ถ้าไม่ระบุ จะหาไฟล์ .csproj ตัวแรกในรีโปให้)
#   TARGET_FRAMEWORK        — TFM ที่ต้องการ evaluate เช่น "net9.0-android"
#                             (จำเป็นสำหรับ multi-target project อย่าง MAUI ที่มี
#                             หลาย TFM พร้อมกัน — ไม่งั้น evaluation จะกำกวม)
#   FAILED_STEP             — ชื่อ step ที่ทำให้ build พัง ปกติไม่ต้องส่งมาเอง
#                             สคริปต์จะอ่านจากไฟล์ ci-failed-step.txt ที่แต่ละ step
#                             ใน CI workflow เขียนไว้ก่อน exit non-zero โดยอัตโนมัติ
#                             (ดู resolve_failed_step()) — ใส่ env var นี้มาตรงๆ
#                             เพื่อ override ก็ได้ (เช่น เวลาทดสอบสคริปต์)
#   ERROR_MESSAGE           — ข้อความ error แบบสั้น (HTML-escaped แล้ว) ปกติไม่ต้อง
#                             ส่งมาเอง สคริปต์จะดึงให้อัตโนมัติตาม FAILED_STEP
#                             (ดู extract_error_message()): Build → grep จาก
#                             build.log, Run tests → parse JUnit XML จาก
#                             test-results/results.xml, Lint shell scripts →
#                             อ่านจาก shellcheck.log
#   FIREBASE_URL            — Firebase App Distribution URL
#   FIREBASE_SETUP_URLS     — pipe-separated setup links: "label=url|label=url"
#                             e.g. "iOS=https://...|Android=https://..."
#   PLAY_STORE_URL          — Google Play Store URL
#   TESTFLIGHT_URL          — TestFlight URL
#   SETUP_ANDROID_URL       — prod setup instruction URL (Android)
#   SETUP_IOS_URL           — prod setup instruction URL (iOS)

set -euo pipefail

TAG_REGEX='^([a-zA-Z]+)-v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]{6})$'
MAX_RETRIES=3
RETRY_DELAY=5
FIREBASE_URL="https://appdistribution.firebase.google.com/testerapps/1:756920477740:android:b0c725c90101591bc38989/releases/3qschsmu3moq8?utm_source=firebase-console"
FIREBASE_SETUP_URLS="คู่มือการติดตั้ง=https://docs.google.com/document/d/1tZNLOr_Bd5ikrx48yTOW1HixDnIUofcAqkcOPfP4Wb0/edit?usp=sharing"
PLAY_STORE_URL="https://play.google.com/store/apps/details?id=thes.mana.client"
TESTFLIGHT_URL="https://testflight.apple.com/join/wrJSJ3QL"
SETUP_ANDROID_URL="https://docs.google.com/document/d/1PEds3PaHYoqvTQnrW-xXlsSYAc-kO6JcnMUTKQT6Co8/edit?usp=sharing"
SETUP_IOS_URL="https://docs.google.com/document/d/1JTZD4OCtpNL5o4S7SNRZdxrvEWc5s9C6YKlAuDxGjGE/edit?usp=sharing"

# --- Validate required env vars ---
: "${TELEGRAM_BOT_TOKEN:?ERROR: TELEGRAM_BOT_TOKEN is not set}"
: "${TELEGRAM_CHAT_ID:?ERROR: TELEGRAM_CHAT_ID is not set}"
: "${BUILD_STATUS:?ERROR: BUILD_STATUS is not set}"

# --- Normalize CI-specific variables ---
normalize_ci_vars() {
  if [ "${CIRCLECI:-}" = "true" ]; then
    REF_NAME="${CIRCLE_TAG:-$CIRCLE_BRANCH}"
    TAG_NAME="${CIRCLE_TAG:-}"
    BUILD_URL="${CIRCLE_BUILD_URL}"
    BUILD_NUMBER="${CIRCLE_BUILD_NUM}"
  elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    REF_NAME="${GITHUB_REF_NAME}"
    TAG_NAME=$([ "${GITHUB_REF_TYPE}" = "tag" ] && echo "${GITHUB_REF_NAME}" || echo "")
    BUILD_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    BUILD_NUMBER="${GITHUB_RUN_NUMBER}"
  else
    echo "ERROR: Unknown CI environment" >&2
    exit 1
  fi

  if [ -n "${TAG_NAME}" ]; then
    IS_TAG="true"
  else
    IS_TAG="false"
  fi

  COMMIT_MSG=$(git log -1 --pretty=format:"%s")
  NL=$'\n'
}

# --- Check Obfuscate from build log ---
check_obfuscate() {
  if [ -f "build.log" ] && grep -q "Successfully Protected!" build.log; then
    OBFUSCATE="true"
  else
    OBFUSCATE="false"
  fi
}

check_app_name() {
  if [ -n "${APP_NAME:-}" ]; then
    return
  fi

  if ! command -v dotnet > /dev/null 2>&1; then
    APP_NAME=""
    return
  fi

  local project_path="${PROJECT_PATH:-}"
  if [ -z "${project_path}" ]; then
    project_path=$(find . -maxdepth 4 -name "*.csproj" -not -path "*/obj/*" -not -path "*/bin/*" 2>/dev/null | head -n1)
  fi

  if [ -z "${project_path}" ]; then
    echo "WARN: no .csproj found to resolve ApplicationTitle (set PROJECT_PATH to override)" >&2
    APP_NAME=""
    return
  fi

  local get_prop_args=(-getProperty:ApplicationTitle)
  if [ -n "${TARGET_FRAMEWORK:-}" ]; then
    get_prop_args+=(-p:TargetFramework="${TARGET_FRAMEWORK}")
  fi

  APP_NAME=$(dotnet build "${project_path}" "${get_prop_args[@]}" 2>/dev/null | tr -d '\r') || true
  APP_NAME="${APP_NAME:-}"

  if [ -z "${APP_NAME}" ]; then
    echo "WARN: ApplicationTitle is empty/unresolved from ${project_path} (multi-target project? try setting TARGET_FRAMEWORK)" >&2
  fi
}

# --- Get tags pointing to current commit ---
check_branch_tags() {
  local tags
  tags=$(git tag --contains HEAD 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  BRANCH_TAGS="${tags:-"-"}"
}

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

resolve_failed_step() {
  if [ -n "${FAILED_STEP:-}" ]; then
    return 
  fi

  if [ -f "ci-failed-step.txt" ]; then
    FAILED_STEP=$(head -n1 ci-failed-step.txt | tr -d '\r\n')
  else
    FAILED_STEP="Unknown step"
  fi
}

extract_error_message() {
  ERROR_MESSAGE=""

  case "${FAILED_STEP}" in
    "Build")
      if [ -f "build.log" ]; then
        ERROR_MESSAGE=$(grep -oE 'error (CS|MSB|NETSDK|NU)[0-9]+:.*' build.log | head -n 5 || true)
      fi
      ;;

    "Run tests")
      if [ -f "test-results/results.xml" ] && command -v python3 > /dev/null 2>&1; then
        ERROR_MESSAGE=$(python3 - "test-results/results.xml" <<'PYEOF' 2>/dev/null || true
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)

count = 0
for node in root.iter():
    if node.tag in ("failure", "error") and count < 5:
        raw = (node.get("message") or node.text or "").strip()
        first_line = raw.splitlines()[0] if raw else "(no message)"
        print(f"{node.tag}: {first_line}")
        count += 1
PYEOF
)
      fi
      ;;

    "Lint shell scripts")
      if [ -f "shellcheck.log" ]; then
        ERROR_MESSAGE=$(grep -E '^In .* line [0-9]+:|SC[0-9]{4}' shellcheck.log | head -n 5 || true)
      fi
      ;;

    *)
      ;;
  esac

  if [ -n "${ERROR_MESSAGE}" ]; then
    ERROR_MESSAGE=$(printf '%s' "${ERROR_MESSAGE}" | head -n 5 | cut -c1-300 | html_escape)
  fi
}

# --- Parse tag ---
parse_tag() {
  APP_VERSION="-"
  SLOT_KEY=""
  SLOT_DISPLAY=""

  if [ "${IS_TAG}" = "true" ] && [[ ${TAG_NAME} =~ ${TAG_REGEX} ]]; then
    SLOT_KEY="${BASH_REMATCH[1]}"
    APP_VERSION="v${BASH_REMATCH[2]}"
    case ${SLOT_KEY} in
      sand)    SLOT_DISPLAY="Sandbox" ;;
      dev)     SLOT_DISPLAY="Development" ;;
      dev*)    SLOT_DISPLAY="Dev-${SLOT_KEY#dev}" ;;
      stg)     SLOT_DISPLAY="Staging" ;;
      rel)     SLOT_DISPLAY="Release" ;;
      *)       SLOT_DISPLAY=$(echo "${SLOT_KEY}" | tr '[:lower:]' '[:upper:]') ;;
    esac
  fi
}

_append_download_links() {
  case ${SLOT_KEY} in
    rel|stg)
      # Production environments → links filtered by PLATFORM
      case "${PLATFORM:-}" in
        Android)
          if [ -n "${PLAY_STORE_URL:-}" ]; then
            MESSAGE+="${NL}<b>Link Download (Android)</b>  <a href=\"${PLAY_STORE_URL}\">Google play store (Internal Beta)</a>${NL}"
          fi
          if [ -n "${SETUP_ANDROID_URL:-}" ]; then
            MESSAGE+="<b>setup instruction</b>  <a href=\"${SETUP_ANDROID_URL}\">Link</a>${NL}"
          fi
          ;;
        iOS)
          if [ -n "${TESTFLIGHT_URL:-}" ]; then
            MESSAGE+="${NL}<b>Link Download (iOS)</b>  <a href=\"${TESTFLIGHT_URL}\">Testflight invitation</a>${NL}"
          fi
          if [ -n "${SETUP_IOS_URL:-}" ]; then
            MESSAGE+="<b>setup instruction</b>  <a href=\"${SETUP_IOS_URL}\">Link</a>${NL}"
          fi
          ;;
        *)
          if [ -n "${PLAY_STORE_URL:-}" ]; then
            MESSAGE+="${NL}<b>Link Download (Android)</b>  <a href=\"${PLAY_STORE_URL}\">Google play store (Internal Beta)</a>${NL}"
          fi
          if [ -n "${TESTFLIGHT_URL:-}" ]; then
            MESSAGE+="<b>Link Download (iOS)</b>  <a href=\"${TESTFLIGHT_URL}\">Testflight invitation</a>${NL}"
          fi
          if [ -n "${SETUP_ANDROID_URL:-}" ]; then
            MESSAGE+="<b>setup instruction (Android)</b>  <a href=\"${SETUP_ANDROID_URL}\">Link</a>${NL}"
          fi
          if [ -n "${SETUP_IOS_URL:-}" ]; then
            MESSAGE+="<b>setup instruction (iOS)</b>  <a href=\"${SETUP_IOS_URL}\">Link</a>${NL}"
          fi
          ;;
      esac
      ;;
    *)
      # Dev/Sandbox/non-tag → Firebase
      if [ -n "${FIREBASE_URL:-}" ]; then
        MESSAGE+="${NL}🔥 <b>Link Download</b>  <a href=\"${FIREBASE_URL}\">Firebase app distribute</a>${NL}"
      fi
      if [ -n "${FIREBASE_SETUP_URLS:-}" ]; then
        MESSAGE+="⚙️ <b>  </b>${NL}"
        local item label url
        local IFS='|'
        for item in ${FIREBASE_SETUP_URLS}; do
          label="${item%%=*}"
          url="${item#*=}"
          MESSAGE+="• <a href=\"${url}\">${label}</a>${NL}"
        done
      fi
      ;;
  esac
}

# --- Build message ---
build_message() {
  local platform_suffix="iOS/Android"
  if [ -n "${PLATFORM:-}" ]; then
    platform_suffix=" ${PLATFORM}"
  fi

  if [ "${BUILD_STATUS}" = "success" ]; then
    MESSAGE="✅${platform_suffix}${NL}"
    MESSAGE+="🔗 <b>Build ID</b>  <a href=\"${BUILD_URL}\">#${BUILD_NUMBER}</a>${NL}"
    MESSAGE+="⏳ <b>Version</b>  ${APP_VERSION}${NL}"
    MESSAGE+="🌿 <b>Branch</b>  ${REF_NAME}${NL}"

    if [ -n "${APP_NAME:-}" ]; then
      MESSAGE+="<b>App name</b>  ${APP_NAME}${NL}"
    fi

    if [ -n "${SLOT_DISPLAY}" ]; then
      MESSAGE+="<b>Ring</b>  ${SLOT_DISPLAY}${NL}"
    fi

    MESSAGE+="🔒 <b>Obfuscate</b>  ${OBFUSCATE}${NL}"
    MESSAGE+="<b>Tags</b>  ${BRANCH_TAGS}${NL}"
    MESSAGE+="📌 <b>Commit</b>  ${COMMIT_MSG}${NL}"

    _append_download_links

  else
    # --- Failed ---
    MESSAGE="❌${platform_suffix}${NL}"
    MESSAGE+="⚠️ <b>Failed step</b>  ${FAILED_STEP:-Unknown step}${NL}"
    if [ -n "${ERROR_MESSAGE:-}" ]; then
      MESSAGE+="📋 <b>Error detail</b>${NL}<pre>${ERROR_MESSAGE}</pre>${NL}"
    else
      MESSAGE+="📋 <b>Error detail</b>  ไม่พบรายละเอียด — เช็กที่ลิงก์ Build ID ด้านล่าง${NL}"
    fi
    MESSAGE+="${NL}"
    MESSAGE+="🔗 <b>Build ID</b>  <a href=\"${BUILD_URL}\">#${BUILD_NUMBER}</a>${NL}"
    MESSAGE+="🔢 <b>Version</b>  ${APP_VERSION}${NL}"
    MESSAGE+="🌿 <b>Branch</b>  ${REF_NAME}${NL}"

    if [ -n "${APP_NAME:-}" ]; then
      MESSAGE+="<b>App name</b>  ${APP_NAME}${NL}"
    fi

    MESSAGE+="🔒 <b>Obfuscate</b>  ${OBFUSCATE}${NL}"
    MESSAGE+="<b>Tags</b>  ${BRANCH_TAGS}${NL}"
    MESSAGE+="<b>Commit</b>  ${COMMIT_MSG}${NL}"
  fi
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
check_app_name
check_branch_tags
parse_tag

if [ "${BUILD_STATUS}" = "failed" ]; then
  resolve_failed_step
  extract_error_message
fi

build_message
send_notification
