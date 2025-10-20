#!/bin/bash
APP_BIN_NAME=$1
APP_VERSION=$2
TARGET_PLATFORM=$3
USER_CMD=$4
BUILD_MODE=$5

echo APP_BIN_NAME=$APP_BIN_NAME
echo APP_VERSION=$APP_VERSION
echo TARGET_PLATFORM=$TARGET_PLATFORM
echo USER_CMD=$USER_CMD
echo BUILD_MODE=$BUILD_MODE

USER_SW_VER=`echo $APP_VERSION | cut -d'-' -f1`

echo "Start Compile"
set -e

SYSTEM=`uname -s`
echo "system:"$SYSTEM
if [ $SYSTEM = "Linux" ]; then
	TOOL_DIR=package_tool/linux
	OTAFIX=${TOOL_DIR}/otafix
	ENCRYPT=${TOOL_DIR}/encrypt
	BEKEN_PACK=${TOOL_DIR}/beken_packager
	RT_OTA_PACK_TOOL=${TOOL_DIR}/rt_ota_packaging_tool_cli
	TY_PACKAGE=${TOOL_DIR}/package
	ENCRYPT_NEW=${TOOL_DIR}/cmake_encrypt_crc
else
	TOOL_DIR=package_tool/windows
	OTAFIX=${TOOL_DIR}/otafix.exe
	ENCRYPT=${TOOL_DIR}/encrypt.exe
	BEKEN_PACK=${TOOL_DIR}/beken_packager.exe
	RT_OTA_PACK_TOOL=${TOOL_DIR}/rt_ota_packaging_tool_cli.exe
	TY_PACKAGE=${TOOL_DIR}/package.exe
	ENCRYPT_NEW=${TOOL_DIR}/cmake_encrypt_crc.exe
fi

# NOTE: This path matches your latest repo layout when invoked from bk7231n_os
APP_PATH=./././apps

# Clean obj files for a deterministic build
for i in `find ${APP_PATH}/$APP_BIN_NAME/src -type d`; do
    rm -rf $i/*.o
done

if [ -z $CI_PACKAGE_PATH ]; then
    echo "not is ci build"
else
	make APP_BIN_NAME=$APP_BIN_NAME USER_SW_VER=$USER_SW_VER APP_VERSION=$APP_VERSION clean -C ./
fi

make APP_BIN_NAME=$APP_BIN_NAME USER_SW_VER=$USER_SW_VER APP_VERSION=$APP_VERSION $USER_CMD -j -C ./

echo "Start Combined (BASE/Tuya)"
cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_${APP_VERSION}.bin tools/generate/

cd tools/generate/

# Save a copy for later variant flows
cp ${APP_BIN_NAME}_${APP_VERSION}.bin ${APP_BIN_NAME}_${APP_VERSION}_zeroKeys.bin

# --- BASE path (Tuya keys) ---
if [ "$BUILD_MODE" = "zerokeys" ]; then
	echo "Using zero keys mode - for those non-Tuya devices"
	./${ENCRYPT} ${APP_BIN_NAME}_${APP_VERSION}.bin 00000000 00000000 00000000 00000000 10000
	python mpytools.py bk7231n_bootloader_enc.bin ${APP_BIN_NAME}_${APP_VERSION}_enc.bin
else
	echo "Using usual Tuya path"
	./${ENCRYPT} ${APP_BIN_NAME}_${APP_VERSION}.bin 510fb093 a3cbeadc 5993a17e c7adeb03 10000
	python mpytools.py bk7231n_bootloader_enc.bin ${APP_BIN_NAME}_${APP_VERSION}_enc.bin
fi

./${BEKEN_PACK} config.json

echo "End Combined (BASE)"
cp all_1.00.bin ${APP_BIN_NAME}_QIO_${APP_VERSION}.bin
rm -f all_1.00.bin

cp ${APP_BIN_NAME}_${APP_VERSION}_enc_uart_1.00.bin ${APP_BIN_NAME}_UA_${APP_VERSION}.bin
rm -f ${APP_BIN_NAME}_${APP_VERSION}_enc_uart_1.00.bin

# --- BASE OTA (kept unchanged; partition name = app) ---
echo "generate ota file (BASE)"
./${RT_OTA_PACK_TOOL} -f ${APP_BIN_NAME}_${APP_VERSION}.bin -v $CURRENT_TIME -o ${APP_BIN_NAME}_${APP_VERSION}.rbl -p app -c gzip -s aes -k 0123456789ABCDEF0123456789ABCDEF -i 0123456789ABCDEF
./${TY_PACKAGE} ${APP_BIN_NAME}_${APP_VERSION}.rbl ${APP_BIN_NAME}_UG_${APP_VERSION}.bin ${APP_VERSION:0:31}

# publish base artifacts
echo "$(pwd)"
cp ${APP_BIN_NAME}_${APP_VERSION}.rbl ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_${APP_VERSION}.rbl
cp ${APP_BIN_NAME}_UG_${APP_VERSION}.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_UG_${APP_VERSION}.bin
cp ${APP_BIN_NAME}_UA_${APP_VERSION}.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_UA_${APP_VERSION}.bin
cp ${APP_BIN_NAME}_QIO_${APP_VERSION}.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_QIO_${APP_VERSION}.bin

# --- BK7231M (zero-keys) VARIANT ---
echo "Will do extra step - for zero keys/dogness"
cp ${APP_BIN_NAME}_${APP_VERSION}_zeroKeys.bin ${APP_BIN_NAME}_${APP_VERSION}.bin
./${ENCRYPT} ${APP_BIN_NAME}_${APP_VERSION}.bin 00000000 00000000 00000000 00000000 10000
python mpytools.py bk7231n_bootloader_enc.bin ${APP_BIN_NAME}_${APP_VERSION}_enc.bin
./${BEKEN_PACK} config.json
cp all_1.00.bin ${APP_BIN_NAME}_QIO_${APP_VERSION}.bin
cp ${APP_BIN_NAME}_QIO_${APP_VERSION}.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231M_QIO_${APP_VERSION}.bin
cp ${APP_BIN_NAME}_UA_${APP_VERSION}.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231M_UA_${APP_VERSION}.bin
rm -f all_1.00.bin

#
#  UASCENT steps (4862379A 8612784B 85C5E258 75754528)
#
# Safety: start clean in tools/generate (avoid stale config/image)
rm -f config.json all_1.00.bin

# 1) Prepare bootloader with UASCENT keys
cp bk7231n_bootloader.bin bk7231n_bootloader_uascent.bin
./${ENCRYPT_NEW} -enc bk7231n_bootloader_uascent.bin 4862379A 8612784B 85C5E258 75754528 -crc

# 2) Prepare app image with UASCENT keys
cp ${APP_BIN_NAME}_${APP_VERSION}_zeroKeys.bin ${APP_BIN_NAME}_${APP_VERSION}.bin
echo "Will do UASCENT encrypt"
./${ENCRYPT} ${APP_BIN_NAME}_${APP_VERSION}.bin 4862379A 8612784B 85C5E258 75754528 10000

# 3) Build pack config with the correct (UASCENT) bootloader
echo "Will do UASCENT mpytools.py to generate config.json"
python mpytools.py ./bk7231n_bootloader_uascent_enc.bin ./${APP_BIN_NAME}_${APP_VERSION}_enc.bin

# Guard: verify the config references the UASCENT bootloader
grep -q "bk7231n_bootloader_uascent_enc.bin" config.json || {
  echo "ERROR: Wrong bootloader in UASCENT config.json"; exit 1;
}

# 4) Pack bootloader+app → all_1.00.bin
echo "Will do UASCENT BEKEN_PACK"
./${BEKEN_PACK} config.json

# 5) FINAL COPIES (no staging reuse!)
echo "Will do UASCENT final copies (no staging)"
cp all_1.00.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231N_UASCENT_QIO_${APP_VERSION}.bin
cp ${APP_BIN_NAME}_UA_${APP_VERSION}.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231N_UASCENT_UA_${APP_VERSION}.bin

# 6) UASCENT OTA packaging (same partition name as base; 'app')
echo "generate UASCENT ota file (partition=app)"
./${RT_OTA_PACK_TOOL} \
  -f ${APP_BIN_NAME}_${APP_VERSION}.bin \
  -v $CURRENT_TIME \
  -o OpenBK7231N_UASCENT_${APP_VERSION}.rbl \
  -p app \
  -c gzip -s aes \
  -k 0123456789ABCDEF0123456789ABCDEF \
  -i 0123456789ABCDEF

./${TY_PACKAGE} \
  OpenBK7231N_UASCENT_${APP_VERSION}.rbl \
  OpenBK7231N_UASCENT_UG_${APP_VERSION}.bin \
  ${APP_VERSION:0:31}

# Publish UASCENT OTA artifacts
cp OpenBK7231N_UASCENT_${APP_VERSION}.rbl ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231N_UASCENT_${APP_VERSION}.rbl
cp OpenBK7231N_UASCENT_UG_${APP_VERSION}.bin ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231N_UASCENT_UG_${APP_VERSION}.bin

echo "*************************************************************************"
echo "*************************************************************************"
echo "*************************************************************************"
echo "*********************${APP_BIN_NAME}_$APP_VERSION.bin********************"
echo "*************************************************************************"
echo "**********************COMPILE SUCCESS************************************"
echo "*************************************************************************"

FW_NAME=$APP_NAME
if [ -n "$CI_IDENTIFIER" ]; then
        FW_NAME=$CI_IDENTIFIER
fi

if [ -z "$CI_PACKAGE_PATH" ]; then
    echo "not is ci build"
	exit 0
else
	mkdir -p ${CI_PACKAGE_PATH}

   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_UG_${APP_VERSION}.bin ${CI_PACKAGE_PATH}/$FW_NAME"_UG_"$APP_VERSION.bin || true
   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_UA_${APP_VERSION}.bin ${CI_PACKAGE_PATH}/$FW_NAME"_UA_"$APP_VERSION.bin || true
   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_QIO_${APP_VERSION}.bin ${CI_PACKAGE_PATH}/$FW_NAME"_QIO_"$APP_VERSION.bin || true
   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_${APP_VERSION}.asm ${CI_PACKAGE_PATH}/$FW_NAME"_"$APP_VERSION.asm || true
   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_${APP_VERSION}.axf ${CI_PACKAGE_PATH}/$FW_NAME"_"$APP_VERSION.axf || true
   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/${APP_BIN_NAME}_${APP_VERSION}.map ${CI_PACKAGE_PATH}/$FW_NAME"_"$APP_VERSION.map || true

   # Include UASCENT OTA artifacts in CI bundle too
   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231N_UASCENT_UG_${APP_VERSION}.bin ${CI_PACKAGE_PATH}/$FW_NAME"_UASCENT_UG_"$APP_VERSION.bin || true
   cp ${APP_PATH}/$APP_BIN_NAME/output/$APP_VERSION/OpenBK7231N_UASCENT_${APP_VERSION}.rbl       ${CI_PACKAGE_PATH}/$FW_NAME"_UASCENT_"$APP_VERSION.rbl       || true
fi
