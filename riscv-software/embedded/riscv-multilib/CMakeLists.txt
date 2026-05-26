#
# Copyright (c) 2024-2025, Arm Limited and affiliates.
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
#   - Support only C library newlib
#   - Removed all tests
#   - Build only on linux

# CMake build for a multilib layout of library variants, with each
# variant in a subdirectory and a multilib.yaml file to map flags to
# a variant.

cmake_minimum_required(VERSION 3.20)

project(riscv-multilib)

# Root directory of the RTfE CMake scripts.
cmake_path(GET CMAKE_CURRENT_SOURCE_DIR PARENT_PATH TOOLCHAIN_SOURCE_DIR)
# Root directory of the llvm-project source.
cmake_path(SET llvmproject_src_dir NORMALIZE "${TOOLCHAIN_SOURCE_DIR}/../..")

# Cache variables to be set by user
set(MULTILIB_JSON "" CACHE STRING "JSON file to load library definitions from.")
set(ENABLE_VARIANTS "all" CACHE STRING "Semicolon separated list of variants to build, or \"all\". Must match entries in the json.")
set(C_LIBRARY "newlib" CACHE STRING "Which C library to use.")
set_property(CACHE C_LIBRARY PROPERTY STRINGS newlib picolibc newlib-nano llvmlibc)
set(PROJECT_PREFIX "${CMAKE_BINARY_DIR}/lib-builds" CACHE STRING "Directory to build subprojects in.")
option(
    NUMERICAL_BUILD_NAMES
    "Instead of using the full variant name to label build directories, use an index number. This may help shorten paths."
    OFF
)
set(LLVM_BINARY_DIR "" CACHE PATH "Path to LLVM toolchain build or install root.")
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
if(NOT CMAKE_GENERATOR MATCHES "Ninja")
    if (ENABLE_PARALLEL_LIB_CONFIG OR ENABLE_PARALLEL_LIB_BUILD)
        message(WARNING "Library build parallelization should only be enabled with the Ninja generator.")
    endif()
endif()

# If a compiler launcher such as ccache has been set, it should be
# passed down to each subproject build.
set(compiler_launcher_cmake_args "")
if(CMAKE_C_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}")
endif()
if(CMAKE_CXX_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER}")
endif()

# Arguments to pass down to the library projects.
foreach(arg
    LLVM_BINARY_DIR
)
    if(${arg})
        list(APPEND passthrough_dirs "-D${arg}=${${arg}}")
    endif()
endforeach()

find_package(Python3 REQUIRED COMPONENTS Interpreter) # needed by fetch_*.cmake

include(ExternalProject)
if(C_LIBRARY STREQUAL picolibc)
    include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_picolibc.cmake)
    list(APPEND passthrough_dirs "-DFETCHCONTENT_SOURCE_DIR_PICOLIBC=${FETCHCONTENT_SOURCE_DIR_PICOLIBC}")
elseif(C_LIBRARY MATCHES "^newlib")
    include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_newlib.cmake)
    list(APPEND passthrough_dirs "-DFETCHCONTENT_SOURCE_DIR_NEWLIB=${FETCHCONTENT_SOURCE_DIR_NEWLIB}")
endif()

# Target for any dependencies to build the runtimes project.
add_custom_target(runtimes-depends)
# )

if(ENABLE_PARALLEL_LIB_CONFIG OR ENABLE_PARALLEL_LIB_BUILD)
    # Additional targets to build the variant subprojects in parallel.
    # The build steps can use multible jobs to compile in parallel, but
    # the configuration steps are largely single threaded. This creates a
    # bottleneck if each variant is built in series.
    # It is significantly faster to run all the subproject configuration
    # steps in parallel, run the build steps, then run the next set of
    # configuration steps in parallel, etc.
    set(
        subtargets
        compiler_rt-configure
        compiler_rt-build
        clib-configure
        clib-build
        cxxlibs-configure
        cxxlibs-build
    )
    set(subtarget_deps none ${subtargets})
    list(REMOVE_AT subtarget_deps 6)

    foreach(subtarget subtarget_dep IN ZIP_LISTS subtargets subtarget_deps)
        add_custom_target(${subtarget}-all)
        if(NOT subtarget_dep STREQUAL "none")
            add_dependencies(${subtarget}-all ${subtarget_dep}-all)
        endif()
    endforeach()
endif()

# Read the JSON file to load a multilib configuration.
file(READ ${MULTILIB_JSON} multilib_json_str)
string(JSON multilib_defs GET ${multilib_json_str} "libs")

# Optional list of flag mappings (auto-detected flag -> synthetic flags).
string(JSON mappings_defs ERROR_VARIABLE mappings_err GET ${multilib_json_str} "mappings")
if(mappings_err)
    set(mappings_defs "[]")
endif()

string(JSON lib_count LENGTH ${multilib_defs})
math(EXPR lib_count_dec "${lib_count} - 1")

foreach(lib_idx RANGE ${lib_count_dec})
    string(JSON lib_def GET ${multilib_defs} ${lib_idx})
    string(JSON variant GET ${lib_def} "variant")
    set(additional_cmake_args "")

    if(variant IN_LIST ENABLE_VARIANTS OR ENABLE_VARIANTS STREQUAL "all")
        string(JSON variant_multilib_flags GET ${lib_def} "flags")
        string(JSON variant_multilib_dir GET ${lib_def} "dir")
        string(JSON variant_json GET ${lib_def} "json")

         # Sort by target triple
        if(variant MATCHES "^rv64")
            set(parent_dir_name riscv64-unknown-elf)
        else()
            set(parent_dir_name riscv32-unknown-elf)
        endif()
        set(destination_directory "${CMAKE_CURRENT_BINARY_DIR}/multilib/${parent_dir_name}/${variant_multilib_dir}")
        if(variant_multilib_dir STREQUAL "")
            set(directory_to_install "${CMAKE_CURRENT_BINARY_DIR}/multilib/${parent_dir_name}/")
        else()
            get_filename_component(isa_dir ${variant_multilib_dir} DIRECTORY)
            set(directory_to_install "${CMAKE_CURRENT_BINARY_DIR}/multilib/${parent_dir_name}/${isa_dir}")
        endif()
        install(
            DIRECTORY ${directory_to_install}
            DESTINATION ${parent_dir_name}
        )
        set(variant_json_file ${CMAKE_CURRENT_SOURCE_DIR}/json/variants/${variant_json})

        # Read info from the variant specific json.
        file(READ ${variant_json_file} variant_json_str)

        if(NUMERICAL_BUILD_NAMES)
            set(runtimes_id ${lib_idx})
            list(APPEND additional_cmake_args "-DVARIANT_BUILD_ID=${lib_idx}")
        else()
            set(runtimes_id ${variant})
        endif()

        ExternalProject_Add(
            runtimes-${variant}
            STAMP_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/stamp
            BINARY_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/build
            DOWNLOAD_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/dl
            TMP_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/tmp
            SOURCE_DIR ${TOOLCHAIN_SOURCE_DIR}/riscv-runtimes
            INSTALL_DIR ${destination_directory}
            DEPENDS runtimes-depends
            CMAKE_ARGS
            ${compiler_launcher_cmake_args}
            ${passthrough_dirs}
            ${additional_cmake_args}
            -DVARIANT_JSON=${variant_json_file}
            -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
            -DPROJECT_PREFIX=${PROJECT_PREFIX}
            -DVARIANT=${variant}
            STEP_TARGETS build install
            USES_TERMINAL_CONFIGURE FALSE
            USES_TERMINAL_BUILD TRUE
            LIST_SEPARATOR ,
            CONFIGURE_HANDLED_BY_BUILD TRUE
            TEST_EXCLUDE_FROM_MAIN TRUE
        )

        # Add the variant to the multilib yaml
        if(variant_multilib_dir STREQUAL "" OR variant_multilib_dir STREQUAL ".")
            string(APPEND multilib_yaml_content "  - Dir: ${parent_dir_name}\n")
        else()
            string(APPEND multilib_yaml_content "  - Dir: ${parent_dir_name}/${variant_multilib_dir}\n")
        endif()
        string(APPEND multilib_yaml_content "    Flags:\n")
        string(REPLACE " " ";" multilib_flags_list ${variant_multilib_flags})
        foreach(flag ${multilib_flags_list})
            string(APPEND multilib_yaml_content "      - ${flag}\n")
        endforeach()
        string(APPEND multilib_yaml_content "    Group: stdlibs\n")
    endif()

endforeach()

# --- Assemble and install the complete multilib.yaml -------------------------

# Header.
set(multilib_yaml_header
"# Generated by riscv-multilib/CMakeLists.txt. Do not edit by hand.\n\
MultilibVersion: 1.0\n\
\n\
Variants:\n")

# Groups: define 'stdlibs' as exclusive so exactly one variant is selected.
set(multilib_yaml_groups
"\n\
Groups:\n\
  - Name: stdlibs\n\
    Type: Exclusive\n")

# Mappings: emitted from the optional 'mappings' json array. Each entry maps an
# auto-detected flag (regex) to synthetic flags that variants can match on.
set(multilib_yaml_mappings "")
string(JSON mappings_count LENGTH ${mappings_defs})
if(mappings_count GREATER 0)
    string(APPEND multilib_yaml_mappings "\nMappings:\n")
    math(EXPR mappings_count_dec "${mappings_count} - 1")
    foreach(map_idx RANGE ${mappings_count_dec})
        string(JSON map_def GET ${mappings_defs} ${map_idx})
        string(JSON map_match GET ${map_def} "match")
        string(JSON map_flags GET ${map_def} "flags")
        string(APPEND multilib_yaml_mappings "  - Match: ${map_match}\n")
        string(APPEND multilib_yaml_mappings "    Flags:\n")
        string(REPLACE " " ";" map_flags_list ${map_flags})
        foreach(mflag ${map_flags_list})
            string(APPEND multilib_yaml_mappings "      - ${mflag}\n")
        endforeach()
    endforeach()
endif()

# Write and install at lib/clang-runtimes/multilib.yaml.
set(multilib_yaml_path "${CMAKE_CURRENT_BINARY_DIR}/multilib/multilib.yaml")
file(WRITE ${multilib_yaml_path}
    "${multilib_yaml_header}${multilib_yaml_content}${multilib_yaml_groups}${multilib_yaml_mappings}")
install(FILES ${multilib_yaml_path} DESTINATION .)
