cmake_minimum_required(VERSION 3.20)
project(bento7z
    VERSION 0.1.0
    DESCRIPTION "A JSONL and binary-socket CLI/server wrapper around bit7z"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Threads REQUIRED)

# ---- FetchContent dependencies ----
include(FetchContent)

# nlohmann/json
FetchContent_Declare(json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.11.3
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(json)

# bit7z (auto-downloads 7-Zip source via CPM internally)
FetchContent_Declare(bit7z
    GIT_REPOSITORY https://github.com/rikyoz/bit7z.git
    GIT_TAG v4.1.0-beta
    GIT_SHALLOW TRUE
)
# bit7z build options — no legacy IUnknown since we build our own 7z.so
set(BIT7Z_AUTO_FORMAT ON CACHE BOOL "Enable auto format detection" FORCE)
set(BIT7Z_REGEX_MATCHING OFF CACHE BOOL "Disable regex matching" FORCE)
set(BIT7Z_USE_NATIVE_STRING OFF CACHE BOOL "Use UTF-8 strings" FORCE)

FetchContent_MakeAvailable(bit7z)

# ---- Build 7z.so from the 7-Zip source that bit7z already downloaded ----
# The source lives at ${FETCHCONTENT_BASE_DIR}/7-zip-src (defaults to ${CMAKE_BINARY_DIR}/_deps/7-zip-src)
set(SEVEN_ZIP_SRC "${FETCHCONTENT_BASE_DIR}/7-zip-src")
set(SEVEN_ZIP_BUNDLE_DIR "${SEVEN_ZIP_SRC}/CPP/7zip/Bundles/Format7zF")
set(SEVEN_ZIP_SO "${CMAKE_BINARY_DIR}/7z.so")

if(APPLE)
    set(_osx_archs "${CMAKE_OSX_ARCHITECTURES}")
    if(NOT _osx_archs)
        set(_osx_archs "${CMAKE_SYSTEM_PROCESSOR}")
    endif()
    list(LENGTH _osx_archs _osx_arch_count)
    if(_osx_arch_count GREATER 1)
        set(SEVEN_ZIP_ARCH_DESC "Universal arm64 + x86_64")
        add_custom_command(
            OUTPUT ${SEVEN_ZIP_SO}
            COMMAND ${CMAKE_COMMAND} -E echo "Building 7z.so from 7-Zip (${SEVEN_ZIP_ARCH_DESC}, no external codecs)..."
            COMMAND ${CMAKE_MAKE_PROGRAM} -C ${SEVEN_ZIP_BUNDLE_DIR} -f ../../cmpl_mac_arm64.mak LOCAL_FLAGS= "-j"
            COMMAND ${CMAKE_MAKE_PROGRAM} -C ${SEVEN_ZIP_BUNDLE_DIR} -f ../../cmpl_mac_x64.mak LOCAL_FLAGS= "-j"
            COMMAND lipo -create
                "${SEVEN_ZIP_BUNDLE_DIR}/b/m_arm64/7z.so"
                "${SEVEN_ZIP_BUNDLE_DIR}/b/m_x64/7z.so"
                -output "${SEVEN_ZIP_SO}"
            DEPENDS "${SEVEN_ZIP_SRC}/CPP/7zip/cmpl_mac_arm64.mak"
                    "${SEVEN_ZIP_SRC}/CPP/7zip/cmpl_mac_x64.mak"
                    ${SEVEN_ZIP_BUNDLE_DIR}/makefile.gcc
                    ${SEVEN_ZIP_BUNDLE_DIR}/Arc_gcc.mak
                    ${CMAKE_CURRENT_LIST_FILE}
            COMMENT "Compiling Universal 7z.so from 7-Zip source (${SEVEN_ZIP_ARCH_DESC})"
            VERBATIM
        )
    else()
        if(_osx_archs MATCHES "x86_64|amd64|x64")
            set(SEVEN_ZIP_MAKEFILE "../../cmpl_mac_x64.mak")
            set(SEVEN_ZIP_MAKEFILE_DEP "${SEVEN_ZIP_SRC}/CPP/7zip/cmpl_mac_x64.mak")
            set(SEVEN_ZIP_OUT_SO "${SEVEN_ZIP_BUNDLE_DIR}/b/m_x64/7z.so")
            set(SEVEN_ZIP_ARCH_DESC "macOS x86_64")
        else()
            set(SEVEN_ZIP_MAKEFILE "../../cmpl_mac_arm64.mak")
            set(SEVEN_ZIP_MAKEFILE_DEP "${SEVEN_ZIP_SRC}/CPP/7zip/cmpl_mac_arm64.mak")
            set(SEVEN_ZIP_OUT_SO "${SEVEN_ZIP_BUNDLE_DIR}/b/m_arm64/7z.so")
            set(SEVEN_ZIP_ARCH_DESC "Apple Silicon arm64")
        endif()
        set(SEVEN_ZIP_MAKE_ARGS
            -f "${SEVEN_ZIP_MAKEFILE}"
            LOCAL_FLAGS=
            "-j"
        )
        add_custom_command(
            OUTPUT ${SEVEN_ZIP_SO}
            COMMAND ${CMAKE_COMMAND} -E echo "Building 7z.so from 7-Zip (${SEVEN_ZIP_ARCH_DESC}, no external codecs)..."
            COMMAND ${CMAKE_MAKE_PROGRAM} -C ${SEVEN_ZIP_BUNDLE_DIR}
                ${SEVEN_ZIP_MAKE_ARGS}
            COMMAND ${CMAKE_COMMAND} -E copy
                ${SEVEN_ZIP_OUT_SO}
                ${SEVEN_ZIP_SO}
            DEPENDS ${SEVEN_ZIP_MAKEFILE_DEP}
                    ${SEVEN_ZIP_BUNDLE_DIR}/makefile.gcc
                    ${SEVEN_ZIP_BUNDLE_DIR}/Arc_gcc.mak
                    ${CMAKE_CURRENT_LIST_FILE}
            COMMENT "Compiling 7z.so from 7-Zip source (${SEVEN_ZIP_ARCH_DESC})"
            VERBATIM
        )
    endif()
else()
    set(SEVEN_ZIP_MAKEFILE "makefile.gcc")
    set(SEVEN_ZIP_OUT_SO "${SEVEN_ZIP_BUNDLE_DIR}/_o/7z.so")
    set(SEVEN_ZIP_ARCH_DESC "Unix")
    set(SEVEN_ZIP_MAKE_ARGS
        -f makefile.gcc
        "CC=${CMAKE_C_COMPILER}"
        "CXX=${CMAKE_CXX_COMPILER}"
        IS_X64=1
        LOCAL_FLAGS=
        "-j"
    )
    set(SEVEN_ZIP_MAKEFILE_DEP "${SEVEN_ZIP_BUNDLE_DIR}/makefile.gcc")
    add_custom_command(
        OUTPUT ${SEVEN_ZIP_SO}
        COMMAND ${CMAKE_COMMAND} -E echo "Building 7z.so from 7-Zip (${SEVEN_ZIP_ARCH_DESC}, no external codecs)..."
        COMMAND ${CMAKE_MAKE_PROGRAM} -C ${SEVEN_ZIP_BUNDLE_DIR}
            ${SEVEN_ZIP_MAKE_ARGS}
        COMMAND ${CMAKE_COMMAND} -E copy
            ${SEVEN_ZIP_OUT_SO}
            ${SEVEN_ZIP_SO}
        DEPENDS ${SEVEN_ZIP_MAKEFILE_DEP}
                ${SEVEN_ZIP_BUNDLE_DIR}/makefile.gcc
                ${SEVEN_ZIP_BUNDLE_DIR}/Arc_gcc.mak
                ${CMAKE_CURRENT_LIST_FILE}
        COMMENT "Compiling 7z.so from 7-Zip source (${SEVEN_ZIP_ARCH_DESC})"
        VERBATIM
    )
endif()

add_custom_target(sevenzip_so DEPENDS ${SEVEN_ZIP_SO})

# ---- Target ----
add_executable(bento7z
    src/main.cpp
    src/protocol.cpp
    src/format_utils.cpp
    src/path_safety.cpp
    src/compound_tar.cpp
    src/commands.cpp
    src/binary_protocol.cpp
    src/binary_server.cpp
    src/zip_encoding.cpp
)

target_include_directories(bento7z PRIVATE
    ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(bento7z PRIVATE
    bit7z
    nlohmann_json::nlohmann_json
    Threads::Threads
)

# Ensure 7z.so is built before bento7z links
add_dependencies(bento7z sevenzip_so)

# Platform-specific rpath for 7z.so discovery
if(APPLE)
    target_link_libraries(bento7z PRIVATE iconv)
    set_target_properties(bento7z PROPERTIES
        BUILD_RPATH "${CMAKE_BINARY_DIR}"
        INSTALL_RPATH "@loader_path"
    )
elseif(UNIX)
    set_target_properties(bento7z PROPERTIES
        BUILD_RPATH "${CMAKE_BINARY_DIR}"
        INSTALL_RPATH "$ORIGIN"
    )
endif()

# Compiler warnings
if(MSVC)
    target_compile_options(bento7z PRIVATE /W4)
else()
    target_compile_options(bento7z PRIVATE -Wall -Wextra -Wpedantic)
endif()
