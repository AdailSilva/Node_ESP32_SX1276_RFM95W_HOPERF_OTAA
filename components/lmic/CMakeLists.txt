# MCCI LMiC (LoRaWAN MAC in C) as an ESP-IDF component.
# src/ = lmic, aes (and se in 6.x) copied unchanged from the MCCI library;
# hal_esp32.c replaces the Arduino HAL (src/hal of the library is not used).
# Region / radio: project_config/lmic_project_config.h.
file(GLOB _lmic_srcs
    "${CMAKE_CURRENT_LIST_DIR}/src/lmic/*.c"
    "${CMAKE_CURRENT_LIST_DIR}/src/aes/*.c"
    "${CMAKE_CURRENT_LIST_DIR}/src/aes/ideetron/*.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/src/se/drivers/default/*.c")

idf_component_register(
    SRCS ${_lmic_srcs} "hal_esp32.c"
    INCLUDE_DIRS "include" "src" "project_config"
    PRIV_REQUIRES esp_driver_gpio esp_driver_spi esp_timer)

# lmic_config_preconditions.h does: #include CFG_TEXT_1(ARDUINO_LMIC_PROJECT_CONFIG_H)
target_compile_definitions(${COMPONENT_LIB} PUBLIC ARDUINO_LMIC_PROJECT_CONFIG_H=lmic_project_config.h)

# 6.x names the HAL functions lmic_hal_*, 3.3.0 names them hal_*
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/src/se")
    target_compile_definitions(${COMPONENT_LIB} PRIVATE LMIC_ESP32_HAL_V6=1)
else()
    # ESP-IDF itself has a hal_init(): rename the one of LMiC 3.3.0
    # (the Arduino core 3.x had the same clash, see the old sketch notes)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE hal_init=lmic_hal_init)
endif()

# third-party code: keep its warnings as warnings
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error -Wno-unused-variable -Wno-unused-function
    -Wno-maybe-uninitialized -Wno-implicit-fallthrough -Wno-unused-but-set-variable)

# the LMiC headers use "defined" inside macros (lmic/config.h): harmless, but
# ESP-IDF 6 turns that warning into an error for whoever includes lmic.h
target_compile_options(${COMPONENT_LIB} INTERFACE -Wno-expansion-to-defined)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-expansion-to-defined)

# LMiC is C99-era code (e.g. "f()" called with arguments in 3.3.0): GCC 15 of
# ESP-IDF 6 defaults to C23, where "f()" means "f(void)". Build it as gnu17.
target_compile_options(${COMPONENT_LIB} PRIVATE $<$<COMPILE_LANGUAGE:C>:-std=gnu17>)
