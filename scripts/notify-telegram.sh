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
#   FAILED_STEP             — step name that caused failure
#   FIREBASE_URL            — Firebase App Distribution URL
#   FIREBASE_SETUP_URLS     — pipe-separated setup links: "label=url|label=url"
#                             e.g. "iOS=https://...|Android=https://..."
#   PLAY_STORE_URL          — Google Play Store URL
#   TESTFLIGHT_URL          — TestFlight URL
#   SETUP_URL               — prod setup instruction URL

set -euo pipefail

TAG_REGEX='^([a-zA-Z]+)-v([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]{6})$'
MAX_RETRIES=3
RETRY_DELAY=5

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
# ตรวจหา "Successfully Protected!" จาก .NET Reactor output ใน build.log
check_obfuscate() {
  if [ -f "build.log" ] && grep -q "Successfully Protected!" build.log; then
    OBFUSCATE="true"
  else
    OBFUSCATE="false"
  fi
}

# --- Resolve app name directly from the .csproj (no log parsing at all) ---
# ApplicationTitle เป็น static project metadata — รู้ค่าได้จากการ "evaluate" project
# เฉยๆ โดยไม่ต้องรอให้ build รันจบ ต่างจาก Obfuscate ที่เป็น runtime build outcome
# (รู้ผลได้ก็ต่อเมื่อ build จบแล้วเท่านั้น จึงยังต้อง grep จาก build.log อยู่)
#
# ใช้ `dotnet build -getProperty:<PropertyName>` (MSBuild 17.8 / .NET SDK 8.0.300+)
# ซึ่งเมื่อขอ property เดียว จะคืนค่าเป็น plain text ตรงๆ ใช้ใน script ได้ทันที —
# นี่คือวิธีเดียวกับที่จะใช้ตอน migrate เข้า MAUI project จริง (ที่มี ApplicationTitle
# อยู่แล้วโดย default) จึงไม่ต้องแก้ logic ส่วนนี้เลยตอน migrate
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

  # -getProperty ต้องมีอย่างน้อย 1 element เสมอ (กัน "unbound variable" ตอน
  # expand array ว่างภายใต้ set -u บน bash รุ่นเก่า)
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
      prod)    SLOT_DISPLAY="Production" ;;
      *)       SLOT_DISPLAY=$(echo "${SLOT_KEY}" | tr '[:lower:]' '[:upper:]') ;;
    esac
  fi
}

# --- Append download links based on slot ---
# rel/prod → Play Store + TestFlight
# dev/sandbox/staging/non-tag → Firebase
_append_download_links() {
  # icon ในส่วนนี้ใช้แยก "แพลตฟอร์ม/ประเภทลิงก์" เพื่อช่วย scan/tap บนมือถือเร็วขึ้น
  # — ตรงนี้คือส่วน call-to-action หลักของข้อความ success จึงคุ้มที่จะใส่
  case ${SLOT_KEY} in
    rel|prod)
      # Production environments → Play Store + TestFlight
      if [ -n "${PLAY_STORE_URL:-}" ]; then
        MESSAGE+="${NL}🤖 <b>Link Download (Android)</b>  <a href=\"${PLAY_STORE_URL}\">Google play store (Internal Beta)</a>${NL}"
      fi
      if [ -n "${TESTFLIGHT_URL:-}" ]; then
        MESSAGE+="🍎 <b>Link Download (iOS)</b>  <a href=\"${TESTFLIGHT_URL}\">Testflight invitation</a>${NL}"
      fi
      if [ -n "${SETUP_URL:-}" ]; then
        MESSAGE+="⚙️ <b>setup instruction</b>  <a href=\"${SETUP_URL}\">Link android or ios</a>${NL}"
      fi
      ;;
    *)
      # Dev/Sandbox/Staging/non-tag → Firebase
      if [ -n "${FIREBASE_URL:-}" ]; then
        MESSAGE+="${NL}🔥 <b>Link Download</b>  <a href=\"${FIREBASE_URL}\">Firebase app distribute</a>${NL}"
      fi
      if [ -n "${FIREBASE_SETUP_URLS:-}" ]; then
        MESSAGE+="⚙️ <b>Firebase setup instruction</b>${NL}"
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
    # --- Success ---
    # icon scheme: เก็บไว้เฉพาะ field ที่ "ใช้ตัดสินใจ/นำทาง" ได้จริง (ลิงก์, environment,
    # security check) ส่วน field ที่เป็นข้อมูลอ้างอิงประจำ (App name, Tags, Commit)
    # ตั้งใจไม่ใส่ icon — ถ้าใส่ทุกบรรทัดเท่ากันหมด จะไม่มีอะไรเด่นจริง
    MESSAGE="✅${platform_suffix}${NL}"
    MESSAGE+="🔗 <b>Build ID</b>  <a href=\"${BUILD_URL}\">#${BUILD_NUMBER}</a>${NL}"
    MESSAGE+="🔢 <b>Version</b>  ${APP_VERSION}${NL}"
    MESSAGE+="🌿 <b>Branch</b>  ${REF_NAME}${NL}"

    if [ -n "${APP_NAME:-}" ]; then
      MESSAGE+="<b>App name</b>  ${APP_NAME}${NL}"
    fi

    if [ -n "${SLOT_DISPLAY}" ]; then
      # 🎯 เน้นเป็นพิเศษ — บอกว่า build นี้จะไป environment ไหน (dev/staging/release/prod)
      # เป็นข้อมูลที่ผู้รับ notification ใช้ตัดสินใจขั้นต่อไปจริงๆ
      MESSAGE+="🎯 <b>Ring</b>  ${SLOT_DISPLAY}${NL}"
    fi

    MESSAGE+="🔒 <b>Obfuscate</b>  ${OBFUSCATE}${NL}"
    MESSAGE+="<b>Tags</b>  ${BRANCH_TAGS}${NL}"
    MESSAGE+="<b>Commit</b>  ${COMMIT_MSG}${NL}"

    _append_download_links

  else
    # --- Failed ---
    MESSAGE="❌${platform_suffix}${NL}"
    # ⚠️ ข้อมูลที่ actionable ที่สุดในข้อความ failed — ต้องดึงสายตาก่อนสิ่งอื่นทั้งหมด
    MESSAGE+="⚠️ <b>Error message</b>  ${FAILED_STEP:-}${NL}"
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
build_message
send_notification
