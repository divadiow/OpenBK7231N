#!/bin/bash
# Revised build.sh — always use zero-keys bootloader for BK7231M QIO,
# keep BK7231N and other platforms untouched.
#
# Usage:
#   ./build.sh <APP_BIN_NAME> <APP_VERSION> <TARGET_PLATFORM> <USER_CMD> <BUILD_MODE>
#
# Notes:
# - This script expects the usual OpenBK7231* toolchain layout in the working dir.
# - It will only engage the zero-keys bootloader path for platforms matching *BK7231M*.
# - BK7231N and others follow the default (Tuya-key) flow.
#
# Exit on errors
set -e

APP_BIN_NAME=$1
APP_VERSION=$2
TARGET_PLATFORM=$3
USER_CMD=$4
BUILD_MODE=$5

# Defaults for tool names if not provided by environment
ENCRYPT=${ENCRYPT:-encrypt}
BEKEN_PACK=${BEKEN_PACK:-beken_pack}

# Path to app (relative to this script's folder) for final copies
APP_PATH=${APP_PATH:-platforms/bk7231n/bk7231n_os}

# Normalize + detect platform early (case-insensitive match for any BK7231M variant)
PLAT_UPPER="$(echo "${TARGET_PLATFORM:-}" | tr '[:lower:]' '[:upper:]')"
case "$PLAT_UPPER" in
  *BK7231M*)
    IS_M_PLATFORM=1
    ;;
  *)
    IS_M_PLATFORM=0
    ;;
esac

echo "APP_BIN_NAME=${APP_BIN_NAME}"
echo "APP_VERSION=${APP_VERSION}"
echo "TARGET_PLATFORM=${TARGET_PLATFORM}"
echo "USER_CMD=${USER_CMD}"
echo "BUILD_MODE=${BUILD_MODE}"
echo "PLAT_UPPER=${PLAT_UPPER}  IS_M_PLATFORM=${IS_M_PLATFORM}"
echo

# Derive simple SW version (strip any -suffix)
USER_SW_VER=$(echo "$APP_VERSION" | cut -d'-' -f1)

echo "==> Starting compile"
make clean || true
make APP_BIN_NAME="${APP_BIN_NAME}" APP_VERSION="${APP_VERSION}" TARGET_PLATFORM="${TARGET_PLATFORM}" USER_CMD="${USER_CMD}" BUILD_MODE="${BUILD_MODE}"

# Expect these artifacts from the build system (names as per original toolchain):
#   ${APP_BIN_NAME}_${APP_VERSION}.bin        -> plain app
#   ${APP_BIN_NAME}_${APP_VERSION}_enc.bin    -> encrypted app (produced below)
#   ${APP_BIN_NAME}_${APP_VERSION}.rbl        -> RBL
# We then generate UG/UA/QIO variants.

# -----------------------------------------------------------------------------
# Step 1: Encrypt the APP (standard encrypt call used by upstream toolchain)
# -----------------------------------------------------------------------------
if [ ! -f "${APP_BIN_NAME}_${APP_VERSION}.bin" ]; then
  echo "ERROR: Missing ${APP_BIN_NAME}_${APP_VERSION}.bin (plain app)."
  exit 2
fi

echo "==> Encrypting app"
./${ENCRYPT} "${APP_BIN_NAME}_${APP_VERSION}.bin" 00000000 00000000 00000000 00000000 10000
mv -f "${APP_BIN_NAME}_${APP_VERSION}_enc.bin" "${APP_BIN_NAME}_${APP_VERSION}_enc.bin" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 2: Build UG / UA via upstream flow (mpytools + beken_pack with default BL)
#         This is the generic flow (Tuya BL etc.). We'll keep it untouched.
# -----------------------------------------------------------------------------
echo "==> Generating config.json (default BL path)"
# Assume default (Tuya) bootloader already prepared in repo as bk7231n_bootloader_enc.bin
if [ ! -f "bk7231n_bootloader_enc.bin" ]; then
  echo "ERROR: Missing bk7231n_bootloader_enc.bin (default encrypted bootloader)."
  echo "Provide it or adjust the path here."
  exit 2
fi

python mpytools.py bk7231n_bootloader_enc.bin "${APP_BIN_NAME}_${APP_VERSION}_enc.bin"
./${BEKEN_PACK} config.json

# This produces all_1.00.bin; use it as baseline QIO unless we re-pack for M
cp -f all_1.00.bin "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin"

# UG/UA copies expected by repo (these should already be produced by upstream build; keep names stable)
if [ ! -f "${APP_BIN_NAME}_UG_${APP_VERSION}.bin" ]; then
  echo "WARN: ${APP_BIN_NAME}_UG_${APP_VERSION}.bin not found; skipping UG size check."
else
  echo "ug_file size:"
  ls -l "${APP_BIN_NAME}_UG_${APP_VERSION}.bin" | awk '{print $5}'
  if [ "$(ls -l "${APP_BIN_NAME}_UG_${APP_VERSION}.bin" | awk '{print $5}')" -gt 679936 ]; then
    echo "ERROR: ${APP_BIN_NAME}_UG_${APP_VERSION}.bin too large (> 679936)"
    rm -f "${APP_BIN_NAME}_UG_${APP_VERSION}.bin"
    exit 1
  fi
fi

if [ ! -f "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" ]; then
  echo "ERROR: expected ${APP_BIN_NAME}_QIO_${APP_VERSION}.bin not produced."
  exit 1
fi

echo "qio_file size:"
ls -l "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" | awk '{print $5}'
if [ "$(ls -l "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" | awk '{print $5}')" -gt 1048576 ]; then
  echo "ERROR: ${APP_BIN_NAME}_QIO_${APP_VERSION}.bin too large (> 1048576)"
  rm -f "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin"
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 3: BK7231M ONLY — pack QIO with ZERO-KEYS bootloader at pack-time
#         (no late 64KB overwrite; we feed zero-keys BL directly to mpytools)
# -----------------------------------------------------------------------------
if [ "${IS_M_PLATFORM}" -eq 1 ]; then
  echo "==> BK7231M detected: enforcing zero-keys bootloader for QIO"

  # Option A: repo ships a ready zero-keys bootloader image (preferred)
  ZERO_KEYS_BL="bk7231n_bootloader_zero_keys.bin"

  # Option B: if only a plain BL exists, you can build a zero-keys encrypted BL here:
  #   ./${ENCRYPT} bk7231n_bootloader.bin 00000000 00000000 00000000 00000000 10000
  #   mv -f bk7231n_bootloader_enc.bin "$ZERO_KEYS_BL"

  if [ ! -f "$ZERO_KEYS_BL" ]; then
    echo "ERROR: Zero-keys bootloader '$ZERO_KEYS_BL' not found."
    echo "Provide it or uncomment the ENCRYPT step above to build it."
    exit 2
  fi

  echo "==> Repacking QIO with zero-keys bootloader"
  python mpytools.py "$ZERO_KEYS_BL" "${APP_BIN_NAME}_${APP_VERSION}_enc.bin"
  ./${BEKEN_PACK} config.json
  cp -f all_1.00.bin "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin"

  # Optional: export explicit BK7231M-named artifacts so you don't flash the wrong one
  mkdir -p "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/"
  cp -f "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/OpenBK7231M_QIO_${APP_VERSION}.bin" || true
  if [ -f "${APP_BIN_NAME}_UA_${APP_VERSION}.bin" ]; then
    cp -f "${APP_BIN_NAME}_UA_${APP_VERSION}.bin"  "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/OpenBK7231M_UA_${APP_VERSION}.bin" || true
  fi
fi

# -----------------------------------------------------------------------------
# Step 4: Optional special modes (e.g., UASCENT) — guarded by BUILD_MODE
# -----------------------------------------------------------------------------
if [ "${BUILD_MODE}" = "uascent" ]; then
  echo "==> BUILD_MODE=uascent (special key path)"
  cp -f bk7231n_bootloader.bin bk7231n_bootloader_uascent.bin
  ./${ENCRYPT} "${APP_BIN_NAME}_${APP_VERSION}.bin" 4862379A 8612784B 85C5E258 75754528 10000
  python mpytools.py bk7231n_bootloader_uascent.bin "${APP_BIN_NAME}_${APP_VERSION}_enc.bin"
  ./${BEKEN_PACK} config.json
  cp -f all_1.00.bin "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin"
  mkdir -p "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/"
  cp -f "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/OpenBK7231N_UASCENT_QIO_${APP_VERSION}.bin" || true
  if [ -f "${APP_BIN_NAME}_UA_${APP_VERSION}.bin" ]; then
    cp -f "${APP_BIN_NAME}_UA_${APP_VERSION}.bin"  "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/OpenBK7231N_UASCENT_UA_${APP_VERSION}.bin" || true
  fi
fi

# -----------------------------------------------------------------------------
# Step 5: Copy common artifacts to output folder
# -----------------------------------------------------------------------------
mkdir -p "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/"

# RBL
if [ -f "${APP_BIN_NAME}_${APP_VERSION}.rbl" ]; then
  cp -f "${APP_BIN_NAME}_${APP_VERSION}.rbl" "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_${APP_VERSION}.rbl"
fi

# UG / UA / QIO (generic names)
if [ -f "${APP_BIN_NAME}_UG_${APP_VERSION}.bin" ]; then
  cp -f "${APP_BIN_NAME}_UG_${APP_VERSION}.bin" "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_UG_${APP_VERSION}.bin"
fi

if [ -f "${APP_BIN_NAME}_UA_${APP_VERSION}.bin" ]; then
  cp -f "${APP_BIN_NAME}_UA_${APP_VERSION}.bin" "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_UA_${APP_VERSION}.bin"
fi

if [ -f "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" ]; then
  cp -f "${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_QIO_${APP_VERSION}.bin"
fi

# -----------------------------------------------------------------------------
# Step 6: CI packaging (if CI_PACKAGE_PATH is set by CI)
# -----------------------------------------------------------------------------
if [ -z "${CI_PACKAGE_PATH:-}" ]; then
  echo "==> Not a CI build; skipping CI packaging."
else
  echo "==> CI packaging to ${CI_PACKAGE_PATH}"
  mkdir -p "${CI_PACKAGE_PATH}"
  FW_NAME="${APP_BIN_NAME}"
  [ -f "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_UG_${APP_VERSION}.bin" ] && \
    cp -f "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_UG_${APP_VERSION}.bin" "${CI_PACKAGE_PATH}/${FW_NAME}_UG_${APP_VERSION}.bin"
  [ -f "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_UA_${APP_VERSION}.bin" ] && \
    cp -f "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_UA_${APP_VERSION}.bin" "${CI_PACKAGE_PATH}/${FW_NAME}_UA_${APP_VERSION}.bin"
  [ -f "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" ] && \
    cp -f "../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_QIO_${APP_VERSION}.bin" "${CI_PACKAGE_PATH}/${FW_NAME}_QIO_${APP_VERSION}.bin"
  # Optional debug artifacts if present
  for ext in asm axf map; do
    f="../../${APP_PATH}/${APP_BIN_NAME}/output/${APP_VERSION}/${APP_BIN_NAME}_${APP_VERSION}.${ext}"
    [ -f "$f" ] && cp -f "$f" "${CI_PACKAGE_PATH}/${FW_NAME}_${APP_VERSION}.${ext}"
  done
fi

echo "==> Done."
