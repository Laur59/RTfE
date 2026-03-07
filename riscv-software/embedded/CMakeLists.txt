#
# Copyright (c) 2022-2025, Arm Limited and affiliates.
#
# Part of the Arm Toolchain project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#
# Copyright (c) 2025-2026, Laurent von Allmen.
# Part of the RISC-V Toolchain for Embedded project, under the Apache License v2.0 with LLVM Exceptions.
#
# Changes:
#   - Modified for building RISC-V compiler
#   - By default use newlib for C library
#   - Removed all tests
#   - Build only on linux


# How to use this file
#
# This file is used to build RISC-V Toolchain for Embedded.
# Recent versions of the following tools are pre-requisites:
# * A toolchain such as Xcode
# * cmake
# * meson
# * ninja
# * python3
# * make
#
# Commands to build:
#   mkdir build
#   cd build
#   cmake -S . -B build -GNinja
#   cmake --build build
#
# To make it easy to get started, the above command checks out
# the newlib Git repos automatically.
#
# If the repos are checked out automatically then cmake will fetch the
# latest changes and check them out every time it runs. To disable this
# behaviour run:
#   cmake . -DFETCHCONTENT_FULLY_DISCONNECTED=ON
#
# If you prefer you can check out and patch the repos manually and use those:
#   mkdir repos
#   git -C repos clone https://sourceware.org/git/newlib-cygwin.git newlib
#   git -C repos/newlib am -k $PWD/patches/newlib/*.patch
#   mkdir build
#   cd build
#   cmake .. -GNinja -DFETCHCONTENT_SOURCE_DIR_NEWLIB=../repos/newlib
#   ninja
#   ninja check-llvm-toolchain
#
# To install the toolchain run:
#   cmake . --install-prefix /absolute/path/to/install/directory
#   ninja install-llvm-toolchain
#
#
# This file is designed to be used in a way that will be familiar to
# LLVM developers. Targets like clang and check-all can be built as usual.
# In addition there are targets to build newlib & runtimes variants.
#
#
# When building the toolchain repeatedly, the most time-consuming part
# can be building the libraries since each one is configured separately.
# To work around this, the variants that get built can be limited using
# the LLVM_TOOLCHAIN_LIBRARY_VARIANTS option e.g.:
#   cmake . '-DLLVM_TOOLCHAIN_LIBRARY_VARIANTS=rv32i_ilp32;rv64imac_lp64'


cmake_minimum_required(VERSION 3.20)

# Add CMake modules of project
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

option(
    PREBUILT_TARGET_LIBRARIES
    "Target libraries are prebuilt so no need to build them"
)
set(TARGET_LIBRARIES_DIR
    "lib/clang-runtimes" CACHE STRING
    "Directory containing the target libraries."
)
set(LLVM_TOOLCHAIN_MULTILIB_JSON
    "${CMAKE_CURRENT_SOURCE_DIR}/riscv-multilib/json/multilib.json" CACHE STRING
    "JSON file defining the multilib."
)
set(LLVM_TOOLCHAIN_LIBRARY_VARIANTS
    "all" CACHE STRING
    "Build only the specified library variants, or \"all\"."
)
option(
    LIBS_DEPEND_ON_TOOLS
    "Automatically ensure tools like clang are up to date before building libraries.
    Set this to OFF if you're working on the libraries and want to avoid rebuilding
    the tools every time you update llvm-project."
    ON
)
option(
    LIBS_USE_COMPILER_LAUNCHER
    "Pass CMAKE_C_COMPILER_LAUNCHER and CMAKE_CXX_COMPILER_LAUNCHER
    down to the library builds, so that programs such as ccache can
    be used to speed up repeated builds. This is not done by default,
    as it can also make the inital build slower due to the cold cache."
)
option(
    ENABLE_PARALLEL_LIB_CONFIG
    "Run the library variant configuration steps in parallel."
    OFF
)
option(
    ENABLE_PARALLEL_LIB_BUILD
    "Run the library variant build steps in parallel."
    OFF
)
set(PARALLEL_LIB_BUILD_LEVELS
    "1" CACHE STRING
    "If ENABLE_PARALLEL_LIB_BUILD is ON, this number of processes will be assigned to each variant built."
)

option(LLVM_TOOLCHAIN_ENABLE_PICOLIBC "Enable building picolibc runtime" ON)
option(LLVM_TOOLCHAIN_ENABLE_NEWLIB "Enable building newlib runtime" OFF)
option(LLVM_TOOLCHAIN_ENABLE_NEWLIB_NANO "Enable building newlib-nano runtime" OFF)
option(LLVM_TOOLCHAIN_ENABLE_LLVMLIBC "Enable building LLVM libc runtime" OFF)

option(
    SHORT_BUILD_PATHS
    "Shorten the lengths of internal build paths, which may help with OS path
    length limits. This replaces the variant suffixes in build directories with
    index numbers, which is shorter but less descriptive."
    OFF
)

option(
    ENABLE_MULTILIB_HEADER_OPTIMISATION "Enable multilib header optimisation phase"
    OFF
)

# option(LLVM_TOOLCHAIN_LIBRARY_OVERLAY_INSTALL
#     "Make cpack build an overlay package that can be unpacked over the main toolchain to install a secondary set of libraries based on newlib or llvm-libc."
#     ${overlay_install_default})

set(LLVM_TOOLCHAIN_ENABLED_LIBCS "")
if(LLVM_TOOLCHAIN_ENABLE_PICOLIBC)
    list(APPEND LLVM_TOOLCHAIN_ENABLED_LIBCS picolibc)
endif()
if(LLVM_TOOLCHAIN_ENABLE_NEWLIB)
    list(APPEND LLVM_TOOLCHAIN_ENABLED_LIBCS newlib)
endif()
if(LLVM_TOOLCHAIN_ENABLE_NEWLIB_NANO)
    list(APPEND LLVM_TOOLCHAIN_ENABLED_LIBCS newlib-nano)
endif()
if(LLVM_TOOLCHAIN_ENABLE_LLVMLIBC)
    list(APPEND LLVM_TOOLCHAIN_ENABLED_LIBCS llvmlibc)
endif()

if(NOT LLVM_TOOLCHAIN_ENABLED_LIBCS)
    message(WARNING
        "No C libraries are enabled. Only the compiler will be built. "
        "Set LLVM_TOOLCHAIN_ENABLE_PICOLIBC, LLVM_TOOLCHAIN_ENABLE_NEWLIB, "
        "LLVM_TOOLCHAIN_ENABLE_NEWLIB_NANO, "
        "or LLVM_TOOLCHAIN_ENABLE_LLVMLIBC to ON to build runtimes.")
endif()

if(LLVM_TOOLCHAIN_ENABLED_LIBCS)
    # The primary libc is the first entry in LLVM_TOOLCHAIN_ENABLED_LIBCS.
    # The order is fixed by the append sequence above (picolibc, newlib,
    # newlib-nano, llvmlibc) and is intentional: picolibc is the default
    # for ATfE, so it should always be the primary when enabled.
    list(GET LLVM_TOOLCHAIN_ENABLED_LIBCS 0 LLVM_TOOLCHAIN_PRIMARY_LIBC)
endif()
list(LENGTH LLVM_TOOLCHAIN_ENABLED_LIBCS LLVM_TOOLCHAIN_ENABLED_LIBCS_COUNT)
set(LLVM_TOOLCHAIN_MULTI_LIB_BUILD OFF)
if(LLVM_TOOLCHAIN_ENABLED_LIBCS_COUNT GREATER 1)
    set(LLVM_TOOLCHAIN_MULTI_LIB_BUILD ON)
endif()

set(BUG_REPORT_URL "https://github.com/Laur59/RTfE/issues" CACHE STRING "")
set(LLVM_DISTRIBUTION_COMPONENTS
    clang-resource-headers
    clang
    dsymutil
    lld
    llvm-ar
    llvm-config
    llvm-cov
    llvm-cxxfilt
    llvm-dwarfdump
    llvm-mc
    llvm-nm
    llvm-objcopy
    llvm-objdump
    llvm-profdata
    llvm-ranlib
    llvm-readelf
    llvm-readobj
    llvm-size
    llvm-strings
    llvm-strip
    llvm-symbolizer
    scan-build
    clang-tidy
    llc
    llvm-dwp
    LTO
    CACHE STRING ""
)
set(LLVM_TOOLCHAIN_DISTRIBUTION_COMPONENTS
    llvm-toolchain-config-files
    llvm-toolchain-libs
    llvm-toolchain-third-party-licenses
    CACHE STRING "Components defined by this CMakeLists that should be
installed by the install-llvm-toolchain target"
)
set(LLVM_ENABLE_PROJECTS clang;lld;clang-tools-extra CACHE STRING "")
set(LLVM_TARGETS_TO_BUILD RISCV CACHE STRING "")
set(LLVM_DEFAULT_TARGET_TRIPLE riscv64-unknown-elf CACHE STRING "")
set(LLVM_APPEND_VC_REV OFF CACHE BOOL "")
set(LLVM_ENABLE_TERMINFO OFF CACHE BOOL "")
set(LLVM_ENABLE_ZSTD OFF CACHE BOOL "")
set(LLVM_ENABLE_LIBXML2 OFF CACHE BOOL "")
set(CLANG_DEFAULT_LINKER lld CACHE STRING "")

# Default to a release build
# (CMAKE_BUILD_TYPE is a special CMake variable so if you want to set
# it then you have to FORCE it).
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE BOOL "" FORCE)
endif()

set(CMAKE_OSX_ARCHITECTURES arm64;x86_64 CACHE STRING "")

find_package(Python3 REQUIRED COMPONENTS Interpreter)

if(NOT CMAKE_C_COMPILER_LAUNCHER AND NOT CMAKE_CXX_COMPILER_LAUNCHER)
    # If ccache is available then use it by default.
    find_program(CCACHE_EXECUTABLE ccache)
    if(CCACHE_EXECUTABLE)
        set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_EXECUTABLE}" CACHE FILEPATH "" FORCE)
        set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_EXECUTABLE}" CACHE FILEPATH "" FORCE)
    endif()
endif()

# If lld is available then use it by default.
find_program(LLD_EXECUTABLE lld)
if(LLD_EXECUTABLE)
    set(LLVM_USE_LINKER lld CACHE STRING "")
endif()

# A lot of files get installed which makes the install messages too
# noisy to be useful so default to disabling them.
set(CMAKE_INSTALL_MESSAGE NEVER CACHE STRING "")

include(ExternalProject)
include(FetchContent)
include(ProcessorCount)

# Check out and patch picolibc or newlib if required.
#
# If you'd rather check out and patch manually then run cmake with
# -DFETCHCONTENT_SOURCE_DIR_PICOLIBC=/path/to/picolibc
# -DFETCHCONTENT_SOURCE_DIR_NEWLIB=/path/to/newlib
#
# By default check out will be silent but this can be changed by running
# cmake with -DFETCHCONTENT_QUIET=OFF
#
# If you want to stop cmake updating the repos then run
# cmake . -DFETCHCONTENT_FULLY_DISCONNECTED=ON
if(LLVM_TOOLCHAIN_ENABLE_PICOLIBC)
    include(fetch_picolibc)
endif()
if(LLVM_TOOLCHAIN_ENABLE_NEWLIB OR LLVM_TOOLCHAIN_ENABLE_NEWLIB_NANO)
    include(fetch_newlib)
endif()

##################################################################################################
# We set all project properties later, this call is just to enable the
# CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT check
project(RiscvToolchainForEmbedded)
# We generally want to install to a local directory to see what the
# output will look like rather than install into the system, so change
# the default accordingly.
# See https://cmake.org/cmake/help/latest/variable/CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT.html
# Note that THIS CODE ONLY WORKS AFTER THE FIRST CALL TO PROJECT so it
# can't be moved after the add_subdirectory(<llvm>) command below as it will be too late -
# the llvm project will set it to the default system install directory.
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
    set(CMAKE_INSTALL_PREFIX
        "${CMAKE_BINARY_DIR}/install"
        CACHE PATH "" FORCE
    )
endif()
##################################################################################################

cmake_path(SET llvmproject_src_dir NORMALIZE "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(LLVM_TOOLCHAIN_LIBC_CONFIG_COMPONENTS "")
list(APPEND LLVM_TOOLCHAIN_DISTRIBUTION_COMPONENTS ${LLVM_TOOLCHAIN_LIBC_CONFIG_COMPONENTS})

add_subdirectory(
    ${llvmproject_src_dir}/llvm llvm
)

get_directory_property(LLVM_VERSION_MAJOR DIRECTORY ${llvmproject_src_dir}/llvm DEFINITION LLVM_VERSION_MAJOR)
get_directory_property(LLVM_VERSION_MINOR DIRECTORY ${llvmproject_src_dir}/llvm DEFINITION LLVM_VERSION_MINOR)
get_directory_property(LLVM_VERSION_PATCH DIRECTORY ${llvmproject_src_dir}/llvm DEFINITION LLVM_VERSION_PATCH)

project(
    RiscvToolchainForEmbedded
    VERSION 1.1
    DESCRIPTION "RISC-V Toolchain for Embedded"
    HOMEPAGE_URL "https://github.com/Laur59/RTfE"
)

# Set package name for shorter archive file name
set(SHORT_PACKAGE_NAME "RTfE")

# Set directory name containing CFI ignore file
set(TARGET_CFI_DIR
    "lib/clang/${LLVM_VERSION_MAJOR}/share" CACHE STRING
    "Directory containing the CFI ignore file."
)

# Set package name and version.
if(DEFINED LLVM_TOOLCHAIN_PACKAGE_NAME)
    set(PACKAGE_NAME ${LLVM_TOOLCHAIN_PACKAGE_NAME})
else()
    set(PACKAGE_NAME ${SHORT_PACKAGE_NAME})
endif()
set(CPACK_PACKAGE_NAME ${PACKAGE_NAME})
set(PACKAGE_VERSION "${LLVM_VERSION_MAJOR}.${LLVM_VERSION_MINOR}.${LLVM_VERSION_PATCH}")
if(DEFINED LLVM_TOOLCHAIN_VERSION_SUFFIX)
    set(PACKAGE_VERSION "${PACKAGE_VERSION}-${LLVM_TOOLCHAIN_VERSION_SUFFIX}")
endif()

# Ensure LLVM tool symlinks are installed.
list(APPEND CMAKE_MODULE_PATH ${llvmproject_src_dir}/llvm/cmake/modules)
llvm_install_symlink(LLVM llvm-ranlib llvm-ar ALWAYS_GENERATE)
llvm_install_symlink(LLVM llvm-readelf llvm-readobj ALWAYS_GENERATE)
llvm_install_symlink(LLVM llvm-strip llvm-objcopy ALWAYS_GENERATE)

# Generate VERSION.txt
# Use add_custom_target instead of add_custom_command so that the target
# is always considered out-of-date, ensuring that VERSION.txt will be
# updated when the git revision changes.
add_custom_target(
    version_txt
    COMMAND
    "${CMAKE_COMMAND}"
    -DRiscvToolchainForEmbedded_VERSION=${RiscvToolchainForEmbedded_VERSION}
    -DRiscvToolchainForEmbedded_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}
    -Dllvmproject_src_dir=${llvmproject_src_dir}
    # at most one of picolibc and newlib options is needed, but easiest to
    # specify both definitions
    -Dpicolibc_SOURCE_DIR=${picolibc_SOURCE_DIR}
    -Dpicolibc_URL=${picolibc_URL}
    -Dnewlib_SOURCE_DIR=${newlib_SOURCE_DIR}
    -Dnewlib_URL=${newlib_URL}
    "-DLLVM_TOOLCHAIN_ENABLED_LIBCS=\"${LLVM_TOOLCHAIN_ENABLED_LIBCS}\""
    -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_version_txt.cmake
    BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/VERSION.txt
)
install(
    FILES "${CMAKE_CURRENT_BINARY_DIR}/VERSION.txt"
    DESTINATION .
    COMPONENT llvm-toolchain-third-party-licenses
)

# Groups all the targets that comprise the toolchain.
add_custom_target(llvm-toolchain ALL)

# Groups all the runtime targets
add_custom_target(llvm-toolchain-runtimes)

add_dependencies(
    llvm-toolchain
    ${LLVM_DISTRIBUTION_COMPONENTS}
)

add_dependencies(
    llvm-toolchain
    llvm-toolchain-runtimes
    version_txt
)

if(LIBS_DEPEND_ON_TOOLS)
    set(lib_tool_dependencies
        clang
        lld
        llvm-ar
        llvm-config
        llvm-nm
        llvm-ranlib
        llvm-strip
    )
endif()

if(LIBS_USE_COMPILER_LAUNCHER)
    if(CMAKE_C_COMPILER_LAUNCHER)
        list(APPEND compiler_launcher_cmake_args "-DCMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}")
    endif()
    if(CMAKE_CXX_COMPILER_LAUNCHER)
        list(APPEND compiler_launcher_cmake_args "-DCMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER}")
    endif()
endif()

# ENABLE_VARIANTS expects a semi-colon separated list.
# To prevent CMake expanding it automatically while passing it
# down, switch to comma separated. Enabling the ExternalProject
# LIST_SEPARATOR option will handle switching it back.
string(REPLACE ";" "," ENABLE_VARIANTS_PASSTHROUGH "${LLVM_TOOLCHAIN_LIBRARY_VARIANTS}")

foreach(libc IN LISTS LLVM_TOOLCHAIN_ENABLED_LIBCS)
    set(multilib_project multilib-${libc})
    # Use a per-libc prefix to avoid subproject build dir conflicts.
    set(multilib_prefix ${CMAKE_BINARY_DIR}/${multilib_project}-builds)
    set(libc_install_dir ${CMAKE_CURRENT_BINARY_DIR}/llvm/${TARGET_LIBRARIES_DIR})
    if(LLVM_TOOLCHAIN_LIBRARY_OVERLAY_INSTALL OR NOT libc STREQUAL LLVM_TOOLCHAIN_PRIMARY_LIBC)
        string(APPEND libc_install_dir "/${libc}")
    endif()

    ExternalProject_Add(
        ${multilib_project}
        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/riscv-multilib
        STAMP_DIR ${multilib_prefix}/multilib/stamp
        BINARY_DIR ${multilib_prefix}/multilib/build
        DOWNLOAD_DIR ${multilib_prefix}/multilib/dl
        TMP_DIR ${multilib_prefix}/multilib/tmp
        INSTALL_DIR ${libc_install_dir}
        DEPENDS ${lib_tool_dependencies}
        CMAKE_ARGS
        ${compiler_launcher_cmake_args}
        -DC_LIBRARY=${libc}
        -DLLVM_BINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}/llvm
        -DMULTILIB_JSON=${LLVM_TOOLCHAIN_MULTILIB_JSON}
        -DENABLE_VARIANTS=${ENABLE_VARIANTS_PASSTHROUGH}
        -DENABLE_MULTILIB_HEADER_OPTIMISATION=${ENABLE_MULTILIB_HEADER_OPTIMISATION}
        -DENABLE_PARALLEL_LIB_CONFIG=${ENABLE_PARALLEL_LIB_CONFIG}
        -DENABLE_PARALLEL_LIB_BUILD=${ENABLE_PARALLEL_LIB_BUILD}
        -DPARALLEL_LIB_BUILD_LEVELS=${PARALLEL_LIB_BUILD_LEVELS}
        -DFETCHCONTENT_SOURCE_DIR_PICOLIBC=${FETCHCONTENT_SOURCE_DIR_PICOLIBC}
        -DFETCHCONTENT_SOURCE_DIR_NEWLIB=${FETCHCONTENT_SOURCE_DIR_NEWLIB}
        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
        -DPROJECT_PREFIX=${multilib_prefix}
        -DNUMERICAL_BUILD_NAMES=${SHORT_BUILD_PATHS}
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        LIST_SEPARATOR ,
        CONFIGURE_HANDLED_BY_BUILD TRUE
        TEST_EXCLUDE_FROM_MAIN TRUE
        STEP_TARGETS build install
    )

    add_dependencies(
        llvm-toolchain-runtimes
        ${multilib_project}-install
    )

endforeach()

install(
    DIRECTORY ${LLVM_BINARY_DIR}/${TARGET_LIBRARIES_DIR}/.
    DESTINATION ${TARGET_LIBRARIES_DIR}
    COMPONENT llvm-toolchain-libs
)

# LLVM-style install
# To use it:
#   ninja install-llvm-toolchain
add_custom_target(
    install-llvm-toolchain
)
foreach(component ${LLVM_TOOLCHAIN_DISTRIBUTION_COMPONENTS})
    add_custom_target(
        install-${component}
        COMMAND
            "${CMAKE_COMMAND}"
            --install ${CMAKE_BINARY_DIR}
            --component ${component}
        USES_TERMINAL
    )
    add_dependencies(
        install-${component}
        llvm-toolchain
    )
    add_dependencies(
        install-llvm-toolchain
        install-${component}
    )
endforeach()
# Also run install-distribution to install the LLVM
# binaries.
add_dependencies(
    install-llvm-toolchain
    install-distribution
)
