# Main component of the node. Without REQUIRES it sees every component
# (esp_wifi, esp_http_server, nvs_flash, mdns, lmic...), like the gateway.
idf_component_register(
    SRCS "node_main.cpp" "node_config.cpp" "node_state.cpp" "node_web.cpp"
         "node_log.c" "node_dns.c" "node_diag.c"
    INCLUDE_DIRS ".")

# The board of the build (scripts/build.sh <board> -> -D BOARD) must match the
# board in the sdkconfig (boards/<board>.defaults -> CONFIG_NODE_BOARD_*).
if(NOT CMAKE_BUILD_EARLY_EXPANSION AND DEFINED BOARD AND NOT "${BOARD}" STREQUAL "${CONFIG_NODE_BOARD_ID}")
    message(FATAL_ERROR "BOARD=${BOARD} but sdkconfig has board ${CONFIG_NODE_BOARD_ID}. "
                        "Delete the old sdkconfig.${BOARD} and build-${BOARD}/ and run scripts/build.sh ${BOARD} again.")
endif()
