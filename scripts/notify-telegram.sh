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
#   SETUP_URL               — prod setup instruction URL

set -euo pipefail

# รูปแบบ tag: SLOT-vMAJOR.MINOR.BUILD-YYMMDD (คั่นด้วย "-" ก่อนวันที่ — เช่น
# rel-v1.1.2562-260525) ให้ตรงกับ tag filter pattern ของทั้ง CircleCI/GitHub Actions
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

# --- HTML-escape dynamic text before inserting into the Telegram message ---
# Telegram parse_mode=HTML จะ parse ทั้งข้อความเป็น HTML — ถ้า ERROR_MESSAGE มี
# &, <, > หลุดเข้าไปดิบๆ (เช่น C# generic "List<string>", XML snippet จาก test
# failure, "a && b" จาก shell) Telegram จะตอบ 400 "can't parse entities" และ
# ปฏิเสธ "ทั้งข้อความ" ไม่ใช่แค่ส่วนที่มีปัญหา — escape ให้ครบก่อนเสมอ
# ลำดับสำคัญ: ต้อง escape `&` ก่อน ไม่งั้นจะไป escape entity (&lt; ฯลฯ) ที่เพิ่งสร้างซ้ำ
html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# --- Resolve which step failed, from the marker file CI steps write ---
# ทุก step ที่อาจพังใน workflow (Lint/Build/Run tests) ห่อด้วย
# `|| { echo "<step name>" > ci-failed-step.txt; exit 1; }` แบบเดียวกันหมด
# (bash ล้วน พกข้ามไปมาระหว่าง CircleCI/GitHub Actions ได้เหมือนกันเป๊ะ)
# ทำให้จุดเดียวนี้พอจะรู้ได้ว่า step ไหนพัง โดยไม่ต้องพึ่ง API เฉพาะของแต่ละ CI
resolve_failed_step() {
  if [ -n "${FAILED_STEP:-}" ]; then
    return  # อนุญาตให้ override ผ่าน env var ได้ (เช่น ตอนทดสอบสคริปต์ตรงๆ)
  fi

  if [ -f "ci-failed-step.txt" ]; then
    FAILED_STEP=$(head -n1 ci-failed-step.txt | tr -d '\r\n')
  else
    # ไม่มี marker file แปลว่าพังก่อนถึง step ที่ห่อ marker ไว้ (เช่น checkout,
    # restore, cache, install tools) — ไม่มี artifact เฉพาะให้ดึง error มาได้
    FAILED_STEP="Unknown step"
  fi
}

# --- Extract a short, relevant error snippet based on which step failed ---
# แยก logic ตามประเภท step เพราะ output แต่ละแบบมีรูปแบบต่างกันโดยสิ้นเชิง:
#   - MSBuild log เป็น plain text บรรทัดเดียวที่ format นิ่งมาก (เหมาะกับ grep)
#   - JUnit XML มี structure ชัดเจน (เหมาะกับ XML parser มากกว่า regex ซึ่งจะพังง่าย
#     ถ้า message มีหลายบรรทัด/มีอักขระพิเศษปนอยู่)
#   - shellcheck log เป็น plain text ที่สรุปไว้ท้ายไฟล์อยู่แล้ว
extract_error_message() {
  ERROR_MESSAGE=""

  case "${FAILED_STEP}" in
    "Build")
      if [ -f "build.log" ]; then
        # MSBuild diagnostic format นิ่งมาก: "<file>(line,col): error CSxxxx: ..."
        # หรือ "error MSBxxxx/NETSDKxxxx/NUxxxx: ..." — grep เฉพาะบรรทัด error
        # (ไม่เอา warning) เอาแค่ 5 รายการแรก กันข้อความยาวเกินจะอ่านบนมือถือ
        ERROR_MESSAGE=$(grep -oE 'error (CS|MSB|NETSDK|NU)[0-9]+:.*' build.log | head -n 5 || true)
      fi
      ;;

    "Run tests")
      if [ -f "test-results/results.xml" ] && command -v python3 > /dev/null 2>&1; then
        # parse JUnit XML ด้วย xml.etree.ElementTree แทน grep/regex — message ของ
        # <failure>/<error> อาจมีหลายบรรทัดหรือมี XML พิเศษปนอยู่ regex จะ fragile
        # กว่า parser ที่เข้าใจ structure จริงๆ — เอาแค่บรรทัดแรกของแต่ละ message
        # และไม่เกิน 5 รายการ
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
        # shellcheck พ่น error/warning พร้อมเลขบรรทัดเป็น plain text อยู่แล้ว —
        # กรองเฉพาะบรรทัดที่ขึ้นต้นด้วย "In ... line N:" หรือมีรหัส SCxxxx
        # ซึ่งเป็นบรรทัดที่ informative ที่สุด ตัดบรรทัด source/pointer (^^^) ทิ้ง
        ERROR_MESSAGE=$(grep -E '^In .* line [0-9]+:|SC[0-9]{4}' shellcheck.log | head -n 5 || true)
      fi
      ;;

    *)
      # ไม่รู้จัก step (พังก่อนถึง step ที่มี marker เช่น checkout/restore/cache)
      # ไม่มี log/artifact เฉพาะให้ดึง — ปล่อยว่างไว้ ให้ build_message ใส่ fallback
      ;;
  esac

  # ตัด + escape เสมอ ไม่ว่าจะดึงมาจากที่ไหน — กันทั้งข้อความยาวเกิน Telegram limit
  # (4096 ตัวอักษรต่อข้อความ) และอักขระ &/</> ที่จะทำให้ parse_mode=HTML พังทั้งข้อความ
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
    # บอกก่อนว่า "step ไหน" พัง (จาก ci-failed-step.txt) แล้วตามด้วย snippet ของ
    # error message จริง (ถ้าดึงได้ — ดู extract_error_message) ห่อด้วย <pre> เพื่อ
    # คงการขึ้นบรรทัดใหม่/จัดรูปแบบ ช่วยให้ตัดสินใจได้ทันทีว่าเป็นปัญหาประเภทไหน
    # โดยไม่ต้องสลับไปเปิด build log ก่อน — ERROR_MESSAGE ผ่าน html_escape มาแล้ว
    # จาก extract_error_message() เสมอ จึงปลอดภัยที่จะแทรกตรงๆ ใน parse_mode=HTML
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

# ดึงข้อมูล error เฉพาะตอน build พัง — ตอน success ไม่มีไฟล์ ci-failed-step.txt/
# build.log/ฯลฯ ที่จะ parse อยู่แล้ว (และ build_message ก็ไม่ได้ใช้ค่าพวกนี้ในสาขา success)
if [ "${BUILD_STATUS}" = "failed" ]; then
  resolve_failed_step
  extract_error_message
fi

build_message
send_notification
