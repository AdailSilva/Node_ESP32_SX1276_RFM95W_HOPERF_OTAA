# LoRaWAN Node OTAA — ESP-IDF project (no Arduino).
# Build: scripts/build.sh <esp32|esp32s3_n16r8|esp32s3_n32r16v> [flash|monitor <port>]
cmake_minimum_required(VERSION 3.16)

# ---------------------------------------------------------------------------
# Firmware version = Git tag. Used by NODE_FW_VERSION (boot banner, web page,
# /info, exported configuration) and by the app descriptor (esp_app_get_description()).
# Taken from, in this order:
#   1. FW_VERSION environment variable (GitHub Actions on a v* tag: tag without the "v")
#   2. git describe --tags --match "v[0-9]*" --dirty
#        on the tag            -> 0.0.1
#        3 commits after it    -> 0.0.1-3-gabc1234
#        uncommitted changes   -> 0.0.1-dirty
#   3. 0.0.0-dev (no Git / no tag yet)
# The value is read when CMake configures the build: after creating a tag, run
# "idf.py reconfigure" (or delete build-<board>/) to pick it up locally.
# ---------------------------------------------------------------------------
if(NOT "$ENV{FW_VERSION}" STREQUAL "")
    set(PROJECT_VER "$ENV{FW_VERSION}")
else()
    execute_process(
        COMMAND git describe --tags --match "v[0-9]*" --dirty
        WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}
        OUTPUT_VARIABLE _git_ver
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
        RESULT_VARIABLE _git_rc)
    if(_git_rc EQUAL 0 AND NOT "${_git_ver}" STREQUAL "")
        string(REGEX REPLACE "^v" "" PROJECT_VER "${_git_ver}")
    else()
        set(PROJECT_VER "0.0.0-dev")
    endif()
endif()
message(STATUS "LoRaWAN Node OTAA firmware version: ${PROJECT_VER}")

# ---------------------------------------------------------------------------
# Board (ESP32 module). One firmware per board, three boards supported:
#
#   BOARD             IDF_TARGET  Module                              Flash / PSRAM
#   esp32             esp32       ESP32-WROOM-32U          (DevKit)   4 MB quad / none
#   esp32s3_n16r8     esp32s3     ESP32-S3-WROOM-1U-N16R8  (DevKit)   16 MB quad (3.3 V) / 8 MB octal
#   esp32s3_n32r16v   esp32s3     ESP32-S3-WROOM-2-N32R16V (DevKit)   32 MB octal (1.8 V) / 16 MB octal
#
# Selected with -D BOARD=<board> (scripts/build.sh does it) or the BOARD
# environment variable. Without it: esp32 -> esp32, esp32s3 -> esp32s3_n32r16v.
# Options loaded, in this order (later files win):
#   sdkconfig.defaults                  common to every board
#   boards/<board>.defaults             flash, PSRAM and CONFIG_NODE_BOARD_* of the module
# Factory pins of the RFM95W per board: main/node_board.h
# ---------------------------------------------------------------------------
if(NOT BOARD AND NOT "$ENV{BOARD}" STREQUAL "")
    set(BOARD "$ENV{BOARD}")
endif()
if(NOT BOARD)
    if(IDF_TARGET STREQUAL "esp32s3" OR "$ENV{IDF_TARGET}" STREQUAL "esp32s3")
        set(BOARD "esp32s3_n32r16v")
    else()
        set(BOARD "esp32")
    endif()
endif()
if(BOARD STREQUAL "esp32s3")              # old name of the WROOM-2 N32R16V build
    set(BOARD "esp32s3_n32r16v")
endif()
set(BOARD "${BOARD}" CACHE STRING "Board: esp32 | esp32s3_n16r8 | esp32s3_n32r16v" FORCE)

if(BOARD STREQUAL "esp32")
    set(_board_target "esp32")
elseif(BOARD STREQUAL "esp32s3_n16r8" OR BOARD STREQUAL "esp32s3_n32r16v")
    set(_board_target "esp32s3")
else()
    message(FATAL_ERROR "BOARD='${BOARD}' is not supported. Use esp32, esp32s3_n16r8 or esp32s3_n32r16v.")
endif()
if(IDF_TARGET AND NOT IDF_TARGET STREQUAL _board_target)
    message(FATAL_ERROR "BOARD='${BOARD}' needs IDF_TARGET=${_board_target} (got '${IDF_TARGET}'). "
                        "Use scripts/build.sh ${BOARD}, it passes both.")
endif()
if(NOT IDF_TARGET)
    set(IDF_TARGET "${_board_target}" CACHE STRING "IDF target")
endif()
set(SDKCONFIG_DEFAULTS "sdkconfig.defaults;boards/${BOARD}.defaults")
message(STATUS "LoRaWAN Node board: ${BOARD} (IDF_TARGET ${_board_target})")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
idf_build_set_property(COMPILE_DEFINITIONS "NODE_FW_VERSION=\"${PROJECT_VER}\"" APPEND)
project(LoRaWAN_Node_OTAA)
