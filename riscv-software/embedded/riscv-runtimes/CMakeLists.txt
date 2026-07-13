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

# CMake build for a library variant, combining a chosen C library
# with builtins from compiler-rt and libcx/libcxxabi/libunwind

cmake_minimum_required(VERSION 3.20)

project(riscv-runtimes)

# Root directory of the RTfE CMake scrpts.
cmake_path(GET CMAKE_CURRENT_SOURCE_DIR PARENT_PATH TOOLCHAIN_SOURCE_DIR)
# Root directory of the llvm-project source.
cmake_path(SET llvmproject_src_dir NORMALIZE "${TOOLCHAIN_SOURCE_DIR}/../..")

# CMake arguments are loaded from the JSON file depending on which C
# library is used, so this must be set before the JSON is processed.
set(C_LIBRARY "newlib" CACHE STRING "Which C library to use.")
set_property(CACHE C_LIBRARY PROPERTY STRINGS picolibc newlib newlib-nano llvmlibc)

set(VARIANT_JSON "" CACHE STRING "JSON file to load args from.")
if(VARIANT_JSON)
    file(READ ${VARIANT_JSON} variant_json_read)
    # Load arguments common to all libraries.
    string(JSON json_args GET ${variant_json_read} "args" "common")
    string(JSON json_args_len LENGTH ${json_args})
    math(EXPR json_args_len_dec "${json_args_len} - 1")
    foreach(json_idx RANGE ${json_args_len_dec})
        string(JSON json_param MEMBER ${json_args} ${json_idx})
        string(JSON json_val GET ${json_args} ${json_param})
        string(JSON json_val_type TYPE ${json_args} ${json_param})
        set(${json_param}_def ${json_val})
    endforeach()
    set(ENABLE_CXX_LIBS_def ON)
else()
    message(FATAL_ERROR "No JSON file provided!")
endif()

# Default values will be populated by the json above.
# Any user specified options will override the default.
set(TARGET_ARCH ${TARGET_ARCH_def} CACHE STRING "Architecture being targetted.")
set(VARIANT ${VARIANT_def} CACHE STRING "Name for the variant, usually /ISA, ABI) pair (e.g., rv32imac with ilp32).")
set(COMPILE_FLAGS ${COMPILE_FLAGS_def} CACHE STRING "Flags required to build the variant.")

set(ENABLE_EXCEPTIONS ${ENABLE_EXCEPTIONS_def} CACHE BOOL "Enable C++ exceptions.")
set(ENABLE_RTTI ${ENABLE_RTTI_def} CACHE BOOL "Enable C++ exceptions.")

set(SUPPORTED_LIBRARY_BUILD_TYPES minsizerelease release releasewithdebuginfo)
if(NOT LIBRARY_BUILD_TYPE_def IN_LIST SUPPORTED_LIBRARY_BUILD_TYPES)
    string(REPLACE ";" ", " SUPPORTED_LIBRARY_BUILD_TYPES_STR "${SUPPORTED_LIBRARY_BUILD_TYPES}")
    message(FATAL_ERROR "Unsupported LIBRARY_BUILD_TYPE value. Supported values are: ${SUPPORTED_LIBRARY_BUILD_TYPES_STR}")
endif()
set(LIBRARY_BUILD_TYPE ${LIBRARY_BUILD_TYPE_def} CACHE STRING "Build type to use in library builds.")
set_property(CACHE LIBRARY_BUILD_TYPE PROPERTY STRINGS ${SUPPORTED_LIBRARY_BUILD_TYPES})

set(ENABLE_CXX_LIBS ${ENABLE_CXX_LIBS_def} CACHE BOOL "Build CXX libs")
# set(ENABLE_LIBC_TESTS ${ENABLE_LIBC_TESTS_def} CACHE BOOL "Enable libc tests (picolibc, newlib, newlib-nano or llvm-libc).")
# set(ENABLE_COMPILER_RT_TESTS ${ENABLE_COMPILER_RT_TESTS_def} CACHE BOOL "Enable compiler-rt tests.")
# set(ENABLE_LIBCXX_TESTS ${ENABLE_LIBCXX_TESTS_def} CACHE BOOL "Enable libcxx tests.")
set(LLVM_BINARY_DIR "" CACHE PATH "Path to LLVM toolchain root to build libraries with")

set(PROJECT_PREFIX "subproj" CACHE STRING "Directory to build subprojects in.")
set(VARIANT_BUILD_ID "${VARIANT}" CACHE STRING "Name to use to identify build directories." )

# Temporary location to collect the libraries as they are built.
set(TEMP_LIB_DIR "${CMAKE_CURRENT_BINARY_DIR}/tmp_install")

find_package(Python3 REQUIRED COMPONENTS Interpreter)

include(ExternalProject)

# If a compiler launcher such as ccache has been set, it should be
# passed down to each subproject build.
set(compiler_launcher_cmake_args "")
if(CMAKE_C_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}")
endif()
if(CMAKE_CXX_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER}")
endif()

set(target_triple "${TARGET_ARCH}-unknown-elf")
set(cpu_family riscv)

set(compile_arch_flags "${COMPILE_FLAGS} --sysroot ${TEMP_LIB_DIR} -I${TEMP_LIB_DIR}/include")
# Compiling the libraries benefits from some extra optimization
# flags, and requires a sysroot or include folder for LLVM libc build.
set(lib_compile_flags "${compile_arch_flags} -ffunction-sections -fdata-sections -fno-ident")

# Generic target names for the C library.
# Declare these now, since compiler-rt requires the 'install' dependency.
add_custom_target(clib-configure)
add_custom_target(clib-build)
add_custom_target(clib-install)

# At this point it's been asserted that LIBRARY_BUILD_TYPE value is valid.
if(LIBRARY_BUILD_TYPE STREQUAL minsizerelease)
    set(LIBRARY_CMAKE_BUILD_TYPE MinSizeRel)
    set(LIBRARY_MESON_BUILD_TYPE minsize)
elseif(LIBRARY_BUILD_TYPE STREQUAL release)
    set(LIBRARY_CMAKE_BUILD_TYPE Release)
    set(LIBRARY_MESON_BUILD_TYPE release)
elseif(LIBRARY_BUILD_TYPE STREQUAL releasewithdebuginfo)
    set(LIBRARY_CMAKE_BUILD_TYPE RelWithDebInfo)
    set(LIBRARY_MESON_BUILD_TYPE debugoptimized)
endif()

###############################################################################
# compiler-rt
###############################################################################

if(NOT target_triple MATCHES "(riscv64-unknown-elf|riscv32-unknown-elf)")
    message(FATAL_ERROR "\
Target triple name \"${target_triple}\" not compatible with compiler-rt.
Use -march to specify the architecture.")
endif()
string(REPLACE "-unknown-" "-unknown-unknown-" normalized_target_triple ${target_triple})

# if(ENABLE_COMPILER_RT_TESTS)
#     # Generate xfails for compiler-rt.
#     set(compiler_rt_lit_xfails_path "${CMAKE_CURRENT_BINARY_DIR}/${VARIANT}_compiler-rt_lit_xfails.txt")
#     set(compiler_rt_lit_args "--path=${LLVM_BINARY_DIR}/bin @${compiler_rt_lit_xfails_path} ${LLVM_LIT_ARGS}")
#     add_custom_target(
#         compiler-rt-xfail-lit-args
#         COMMAND ${Python3_EXECUTABLE}
#             ${CMAKE_CURRENT_SOURCE_DIR}/test-support/xfails.py
#             --variant ${VARIANT}
#             --project compiler-rt
#             --libc ${C_LIBRARY}
#             --output-args ${compiler_rt_lit_xfails_path}
#     )
#
#     set(compiler_rt_test_flags "${lib_compile_flags} ${test_link_flags}")
#     set(
#         compiler_rt_test_cmake_args
#         -DCOMPILER_RT_INCLUDE_TESTS=ON
#         -DCOMPILER_RT_EMULATOR=${lit_test_executor}
#         -DCOMPILER_RT_TEST_COMPILER=${LLVM_BINARY_DIR}/bin/clang
#         -DCOMPILER_RT_TEST_COMPILER_CFLAGS=${compiler_rt_test_flags}
#         -DLLVM_INCLUDE_TESTS=ON
#         -DLLVM_LIT_ARGS=${compiler_rt_lit_args}
#         -DLLVM_EXTERNAL_LIT=${external_lit_path}
#     )
# endif()

# Common compiler_rt flags used by both builtins and profile builds
set(
    compiler_rt_common_flags
    -DCMAKE_AR=${LLVM_BINARY_DIR}/bin/llvm-ar${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_ASM_COMPILER_TARGET=${target_triple}
    -DCMAKE_ASM_FLAGS=${lib_compile_flags}
    -DCMAKE_BUILD_TYPE=${LIBRARY_CMAKE_BUILD_TYPE}
    -DCMAKE_CXX_COMPILER=${LLVM_BINARY_DIR}/bin/clang++${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_CXX_COMPILER_TARGET=${target_triple}
    -DCMAKE_CXX_FLAGS=${lib_compile_flags}
    -DCMAKE_C_COMPILER=${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_C_COMPILER_TARGET=${target_triple}
    -DCMAKE_C_FLAGS=${lib_compile_flags}
    -DCMAKE_INSTALL_MESSAGE=${CMAKE_INSTALL_MESSAGE}
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    -DCMAKE_NM=${LLVM_BINARY_DIR}/bin/llvm-nm${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_RANLIB=${LLVM_BINARY_DIR}/bin/llvm-ranlib${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_SYSTEM_NAME=Generic
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DCOMPILER_RT_BAREMETAL_BUILD=ON
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF
    -DCOMPILER_RT_BUILD_XRAY=OFF
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
    -DLLVM_ENABLE_RUNTIMES=compiler-rt
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
)

ExternalProject_Add(
    compiler_rt
    STAMP_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/stamp
    BINARY_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/build
    DOWNLOAD_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/dl
    TMP_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/tmp
    SOURCE_DIR ${llvmproject_src_dir}/runtimes
    INSTALL_DIR compiler-rt/install
    CMAKE_ARGS
    ${compiler_rt_common_flags}
    ${compiler_launcher_cmake_args}
    -DCOMPILER_RT_BUILD_PROFILE=OFF
    STEP_TARGETS configure build install
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
    USES_TERMINAL_INSTALL TRUE
    LIST_SEPARATOR ,
    CONFIGURE_HANDLED_BY_BUILD TRUE
    INSTALL_COMMAND ${CMAKE_COMMAND} --install .
    # Copy compiler-rt lib directory, moving libraries out of their
    # target-specific subdirectory.
    COMMAND
        ${CMAKE_COMMAND}
        -E copy_directory
        <INSTALL_DIR>/lib/${normalized_target_triple}
        "${TEMP_LIB_DIR}/lib"
)

# Build compiler-rt profile library after the C library is available.
# ExternalProject_Add(
#     compiler_rt_profile
#     STAMP_DIR ${PROJECT_PREFIX}/compiler_rt_profile/${VARIANT_BUILD_ID}/stamp
#     BINARY_DIR ${PROJECT_PREFIX}/compiler_rt_profile/${VARIANT_BUILD_ID}/build
#     DOWNLOAD_DIR ${PROJECT_PREFIX}/compiler_rt_profile/${VARIANT_BUILD_ID}/dl
#     TMP_DIR ${PROJECT_PREFIX}/compiler_rt_profile/${VARIANT_BUILD_ID}/tmp
#     SOURCE_DIR ${llvmproject_src_dir}/runtimes
#     INSTALL_DIR compiler-rt-profile/install
#     DEPENDS compiler_rt-install clib-install
#     CMAKE_ARGS
#     ${compiler_rt_common_flags}
#     ${compiler_launcher_cmake_args}
#     ${compiler_rt_cmake_args}
#     -DCOMPILER_RT_BUILD_BUILTINS=OFF
#     -DCOMPILER_RT_BUILD_PROFILE=ON
#     -DCOMPILER_RT_PROFILE_BAREMETAL=ON
#     STEP_TARGETS configure build install
#     USES_TERMINAL_CONFIGURE TRUE
#     USES_TERMINAL_BUILD TRUE
#     USES_TERMINAL_INSTALL TRUE
#     LIST_SEPARATOR ,
#     CONFIGURE_HANDLED_BY_BUILD TRUE
#     INSTALL_COMMAND ${CMAKE_COMMAND} --install .
#     COMMAND
#         ${CMAKE_COMMAND}
#         -E copy_directory
#         <INSTALL_DIR>/lib/${normalized_target_triple}
#         "${TEMP_LIB_DIR}/lib"
# )

###############################################################################
# picolibc
###############################################################################

if(C_LIBRARY STREQUAL picolibc)
    include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_picolibc.cmake)
    include(${CMAKE_CURRENT_SOURCE_DIR}/to_meson_list.cmake)

    # For building picolibc use Meson.
    # Although picolibc has support for building with CMake, the Meson code
    # is more mature and works better with LLVM.
    find_program(MESON_EXECUTABLE meson REQUIRED)

    if(CMAKE_INSTALL_MESSAGE STREQUAL NEVER)
        set(MESON_INSTALL_QUIET "--quiet")
    endif()

    # TODO: xfail these tests instead of disabling.
    if(target_triple MATCHES "^aarch64")
        set(enable_picolibc_long_double_test false)
    else()
        set(enable_picolibc_long_double_test true)
    endif()

    # Set meson_c_args to a comma-separated list of the clang path
    # and flags e.g. 'path/to/clang', '--target=armv6m-none-eabi',
    # '-march=armv6m'
    set(picolibc_flags "${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX} ${lib_compile_flags}")
    set(picolibcpp_flags "${LLVM_BINARY_DIR}/bin/clang++${CMAKE_EXECUTABLE_SUFFIX} ${lib_compile_flags}")
    if(CMAKE_C_COMPILER_LAUNCHER)
        set(picolibc_flags "${CMAKE_C_COMPILER_LAUNCHER} ${picolibc_flags}")
    endif()
    separate_arguments(picolibc_flags)
    separate_arguments(picolibcpp_flags)
    to_meson_list("${picolibc_flags}" picolibc_meson_flags)
    to_meson_list("${picolibcpp_flags}" picolibcpp_meson_flags)

    configure_file(${CMAKE_CURRENT_SOURCE_DIR}/meson-cross-build.txt.in ${CMAKE_CURRENT_BINARY_DIR}/meson-cross-build.txt @ONLY)

    ExternalProject_Add(
        picolibc
        STAMP_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/stamp
        BINARY_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/build
        DOWNLOAD_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/dl
        TMP_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/tmp
        SOURCE_DIR ${picolibc_SOURCE_DIR}
        INSTALL_DIR ${TEMP_LIB_DIR}
        DEPENDS compiler_rt-install
        CONFIGURE_COMMAND
            ${MESON_EXECUTABLE}
            setup
            -Dincludedir=include
            -Dlibdir=lib
            -Dspecsdir=none
            -Dmultilib=false
            -Ddebug=false
            -Dtests-enable-stack-protector=false
            -Dtest-long-double=false
            -Dtests=false
            --prefix <INSTALL_DIR>
            --cross-file ${CMAKE_CURRENT_BINARY_DIR}/meson-cross-build.txt
            --buildtype=${LIBRARY_MESON_BUILD_TYPE}
            <SOURCE_DIR>
        BUILD_COMMAND ${MESON_EXECUTABLE} compile
        INSTALL_COMMAND ${MESON_EXECUTABLE} install ${MESON_INSTALL_QUIET}
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE
        LIST_SEPARATOR ,
        CONFIGURE_HANDLED_BY_BUILD TRUE
        TEST_EXCLUDE_FROM_MAIN TRUE
        STEP_TARGETS configure build install
    )

#     add_custom_target(check-picolibc)
#     add_dependencies(check-all check-picolibc)
#     if(ENABLE_LIBC_TESTS)
#         # meson builds the tests at the same time as the library.
#         # So reconfigure to enable tests at a later point.
#         ExternalProject_Add_Step(
#             picolibc
#             compile-tests
#             COMMAND ${MESON_EXECUTABLE} setup -Dtests=true --reconfigure <BINARY_DIR> <SOURCE_DIR>
#             COMMAND ${MESON_EXECUTABLE} compile -C <BINARY_DIR>
#             USES_TERMINAL TRUE
#             EXCLUDE_FROM_MAIN TRUE
#         )
#         ExternalProject_Add_StepTargets(picolibc compile-tests)
#         ExternalProject_Add_StepDependencies(
#             picolibc
#             compile-tests
#             picolibc-build
#             compiler_rt-install
#         )
#
#         # Timeout multipliers. The actual timeout value used in testing is:
#         # Timeout in seconds (defined in the picolibc's testing specs) x Timeout multiplier
#         # In general, tests execute slower with FVPs compared to qemu. However certain
#         # variants can also be slower due to features enabled, for example:
#         # * Armv6m big-endian
#         # * Armv7m big-endian
#         # * Armv8.1-M Main PACBTI optimized for code size
#         if(TEST_EXECUTOR STREQUAL fvp)
#             set(timeout_multiplier 2)
#         else()
#             set(timeout_multiplier 1)
#         endif()
#
#         # Step target to run the picolibc test via meson.
#         ExternalProject_Add_Step(
#             picolibc
#             check-meson
#             COMMAND ${MESON_EXECUTABLE} test -C <BINARY_DIR> --no-rebuild -t ${timeout_multiplier}
#             USES_TERMINAL TRUE
#             EXCLUDE_FROM_MAIN TRUE
#             ALWAYS TRUE
#             DEPENDEES compile-tests
#         )
#         ExternalProject_Add_StepTargets(picolibc check-meson)
#
#         # Generate lit wrappers for the tests.
#         set(picolibc_lit_dir ${CMAKE_CURRENT_BINARY_DIR}/picolibc_lit)
#         ExternalProject_Add_Step(
#             picolibc
#             gen-lit-tests
#             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test-support/gen-picolibc-lit-tests.py
#                 --meson ${MESON_EXECUTABLE}
#                 --build <BINARY_DIR>
#                 --output ${picolibc_lit_dir}
#                 --name picolibc-${variant_xml_name}
#                 --timeout-multiplier ${timeout_multiplier}
#             USES_TERMINAL TRUE
#             EXCLUDE_FROM_MAIN TRUE
#             DEPENDEES compile-tests
#         )
#         ExternalProject_Add_StepTargets(picolibc gen-lit-tests)
#
#         # Generate xfails for picolibc.
#         set(picolibc_lit_xfails_path "${picolibc_lit_dir}/${VARIANT}_picolibc_lit_xfails.txt")
#         add_custom_target(
#             picolibc-xfail-lit-args
#             COMMAND ${Python3_EXECUTABLE}
#                 ${CMAKE_CURRENT_SOURCE_DIR}/test-support/xfails.py
#                 --variant ${VARIANT}
#                 --project picolibc
#                 --libc ${C_LIBRARY}
#                 --output-args ${picolibc_lit_xfails_path}
#         )
#
#         set(check_lit_cmd "${Python3_EXECUTABLE} ${external_lit_path} ${picolibc_lit_dir} ${LLVM_LIT_ARGS} @${picolibc_lit_xfails_path}")
#         # LLVM_LIT_ARGS has space separated flags, but the
#         # step COMMAND needs a list of arguments.
#         separate_arguments(check_lit_cmd)
#
#         # Step target to run the picolibc test via lit.
#         ExternalProject_Add_Step(
#             picolibc
#             check-lit
#             COMMAND ${check_lit_cmd}
#             USES_TERMINAL TRUE
#             EXCLUDE_FROM_MAIN TRUE
#             ALWAYS TRUE
#             DEPENDEES gen-lit-tests
#         )
#         ExternalProject_Add_StepTargets(picolibc check-lit)
#         ExternalProject_Add_StepDependencies(
#             picolibc
#             check-lit
#             picolibc-xfail-lit-args
#         )
#         add_dependencies(check-picolibc picolibc-check-lit)
#         add_dependencies(clib-build ${C_LIBRARY}-compile-tests)
#     endif()

endif()

###############################################################################
# picolibc
###############################################################################

if(C_LIBRARY STREQUAL picolibc)
    include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_picolibc.cmake)
    include(${CMAKE_CURRENT_SOURCE_DIR}/to_meson_list.cmake)

    # For building picolibc use Meson.
    # Although picolibc has support for building with CMake, the Meson code
    # is more mature and works better with LLVM.
    find_program(MESON_EXECUTABLE meson REQUIRED)

    if(CMAKE_INSTALL_MESSAGE STREQUAL NEVER)
        set(MESON_INSTALL_QUIET "--quiet")
    endif()

    # TODO: xfail these tests instead of disabling.
    if(target_triple MATCHES "^aarch64")
        set(enable_picolibc_long_double_test false)
    else()
        set(enable_picolibc_long_double_test true)
    endif()

    # Set meson_c_args to a comma-separated list of the clang path
    # and flags e.g. 'path/to/clang', '--target=armv6m-none-eabi',
    # '-march=armv6m'
    set(picolibc_flags "${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX} ${lib_compile_flags}")
    set(picolibcpp_flags "${LLVM_BINARY_DIR}/bin/clang++${CMAKE_EXECUTABLE_SUFFIX} ${lib_compile_flags}")
    if(CMAKE_C_COMPILER_LAUNCHER)
        set(picolibc_flags "${CMAKE_C_COMPILER_LAUNCHER} ${picolibc_flags}")
    endif()
    separate_arguments(picolibc_flags)
    separate_arguments(picolibcpp_flags)
    to_meson_list("${picolibc_flags}" picolibc_meson_flags)
    to_meson_list("${picolibcpp_flags}" picolibcpp_meson_flags)

    configure_file(${CMAKE_CURRENT_SOURCE_DIR}/meson-cross-build.txt.in ${CMAKE_CURRENT_BINARY_DIR}/meson-cross-build.txt @ONLY)

    ExternalProject_Add(
        picolibc
        STAMP_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/stamp
        BINARY_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/build
        DOWNLOAD_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/dl
        TMP_DIR ${PROJECT_PREFIX}/picolibc/${VARIANT_BUILD_ID}/tmp
        SOURCE_DIR ${picolibc_SOURCE_DIR}
        INSTALL_DIR ${TEMP_LIB_DIR}
        DEPENDS compiler_rt-install
        CONFIGURE_COMMAND
            ${MESON_EXECUTABLE}
            setup
            -Dincludedir=include
            -Dlibdir=lib
            -Dspecsdir=none
            -Dmultilib=false
            -Ddebug=false
            -Dtests-enable-stack-protector=false
            -Dtest-long-double=false
            -Dtests=false
            --prefix <INSTALL_DIR>
            --cross-file ${CMAKE_CURRENT_BINARY_DIR}/meson-cross-build.txt
            --buildtype=${LIBRARY_MESON_BUILD_TYPE}
            <SOURCE_DIR>
        BUILD_COMMAND ${MESON_EXECUTABLE} compile
        INSTALL_COMMAND ${MESON_EXECUTABLE} install ${MESON_INSTALL_QUIET}
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE
        LIST_SEPARATOR ,
        CONFIGURE_HANDLED_BY_BUILD TRUE
        TEST_EXCLUDE_FROM_MAIN TRUE
        STEP_TARGETS configure build install
    )
endif()

###############################################################################
# newlib
###############################################################################

if(C_LIBRARY MATCHES "^newlib")
    if(C_LIBRARY STREQUAL newlib-nano)
    else()
        if(LIBRARY_BUILD_TYPE STREQUAL minsizerelease)
            set(newlib_optim_flags "-O2")
        elseif((LIBRARY_BUILD_TYPE STREQUAL release) OR (LIBRARY_BUILD_TYPE STREQUAL releasewithdebuginfo))
            set(newlib_optim_flags "-O2")
        endif()
        set(newlib_flags
            --enable-newlib-io-long-long
            --enable-newlib-register-fini
            --disable-newlib-supplied-syscalls
            --enable-newlib-io-c99-formats
            --disable-nls
            --enable-lite-exit
            --disable-multilib
            --enable-newlib-retargetable-locking
            --enable-newlib-io-float)
    endif()

    include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_newlib.cmake)
    set(build_env
        "CC_FOR_TARGET=${LLVM_BINARY_DIR}/bin/clang -target ${target_triple} -ffreestanding"
        "CXX_FOR_TARGET=${LLVM_BINARY_DIR}/bin/clang++ -target ${target_triple} -ffreestanding"
        "AR_FOR_TARGET=${LLVM_BINARY_DIR}/bin/llvm-ar"
        "NM_FOR_TARGET=${LLVM_BINARY_DIR}/bin/llvm-nm"
        "OBJDUMP_FOR_TARGET=${LLVM_BINARY_DIR}/bin/llvm-objdump"
        "RANLIB_FOR_TARGET=${LLVM_BINARY_DIR}/bin/llvm-ranlib"
        "READELF_FOR_TARGET=${LLVM_BINARY_DIR}/bin/llvm-readelf"
        "STRIP_FOR_TARGET=${LLVM_BINARY_DIR}/bin/llvm-strip"
        "CFLAGS_FOR_TARGET=${flags} ${newlib_optim_flags} ${lib_compile_flags} -Wno-error=implicit-function-declaration -D__USES_INITFINI__ -U_HAVE_INIT_FINI"
        "CCASFLAGS=${flags} ${newlib_optim_flags} ${lib_compile_flags} -Wno-error=implicit-function-declaration -D__USES_INITFINI__ -U_HAVE_INIT_FINI"
    )

    include(ProcessorCount)
    set(make_flags)
    ProcessorCount(nproc)
    if(NOT nproc EQUAL 0)
        set(make_flags -j${nproc})
    endif()

    ExternalProject_Add(
        ${C_LIBRARY}
        STAMP_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${MULTILIB_DIR_def}/stamp
        BINARY_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${MULTILIB_DIR_def}/build
        DOWNLOAD_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${MULTILIB_DIR_def}/dl
        TMP_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${MULTILIB_DIR_def}/tmp
        SOURCE_DIR ${newlib_SOURCE_DIR}
        INSTALL_DIR ${TEMP_LIB_DIR}
        CONFIGURE_COMMAND
            ${CMAKE_COMMAND} -E env ${build_env}
            <SOURCE_DIR>/configure
            --target=${target_triple}
            --prefix "${TEMP_LIB_DIR}"
            --exec_prefix <BINARY_DIR>/tmpinstall
            ${newlib_flags}
        BUILD_COMMAND
            ${CMAKE_COMMAND} -E env ${build_env}
            make ${make_flags}
        INSTALL_COMMAND
            make install
            &&
            ${CMAKE_COMMAND} -E copy_directory
            <BINARY_DIR>/tmpinstall/${target_triple}
            ${TEMP_LIB_DIR}
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE
        # Always run the build command so that incremental builds are correct.
        CONFIGURE_HANDLED_BY_BUILD TRUE
        TEST_EXCLUDE_FROM_MAIN TRUE
        STEP_TARGETS configure build install
    )
endif()

###############################################################################
# llvmlibc
###############################################################################

if(C_LIBRARY STREQUAL llvmlibc)
#     set(test_cmd "${lit_test_executor} @BINARY@")
    set(lib_compile_flags "${lib_compile_flags} -Wno-error=atomic-alignment")

    set(common_llvmlibc_cmake_args
        -DCMAKE_AR=${LLVM_BINARY_DIR}/bin/llvm-ar${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_ASM_COMPILER=${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_ASM_COMPILER_TARGET=${target_triple}
        -DCMAKE_ASM_FLAGS=${lib_compile_flags}
        -DCMAKE_BUILD_TYPE=${LIBRARY_CMAKE_BUILD_TYPE}
        -DCMAKE_CXX_COMPILER=${LLVM_BINARY_DIR}/bin/clang++${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_CXX_COMPILER_TARGET=${target_triple}
        -DCMAKE_CXX_FLAGS=${lib_compile_flags}
        -DCMAKE_C_COMPILER=${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_C_COMPILER_TARGET=${target_triple}
        -DCMAKE_C_FLAGS=${lib_compile_flags}
        -DCMAKE_INSTALL_MESSAGE=${CMAKE_INSTALL_MESSAGE}
        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
        -DCMAKE_NM=${LLVM_BINARY_DIR}/bin/llvm-nm${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_RANLIB=${LLVM_BINARY_DIR}/bin/llvm-ranlib${CMAKE_EXECUTABLE_SUFFIX}
        # Let CMake know we're cross-compiling
        -DCMAKE_SYSTEM_NAME=Generic
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    )

    ExternalProject_Add(
        llvmlibc
        STAMP_DIR ${PROJECT_PREFIX}/llvmlibc/${VARIANT_BUILD_ID}/stamp
        BINARY_DIR ${PROJECT_PREFIX}/llvmlibc/${VARIANT_BUILD_ID}/build
        DOWNLOAD_DIR ${PROJECT_PREFIX}/llvmlibc/${VARIANT_BUILD_ID}/dl
        TMP_DIR ${PROJECT_PREFIX}/llvmlibc/${VARIANT_BUILD_ID}/tmp
        SOURCE_DIR ${llvmproject_src_dir}/runtimes
        INSTALL_DIR llvmlibc/install
        CMAKE_ARGS
        ${compiler_launcher_cmake_args}
        ${common_llvmlibc_cmake_args}
        -DLIBC_TARGET_TRIPLE=${target_triple}
        -DLIBC_CONF_TIME_64BIT=ON
        -DLIBC_CONF_ERRNO_MODE=LIBC_ERRNO_MODE_SHARED
        -DLIBC_CONF_PRINTF_DISABLE_FLOAT=OFF
        -DLIBC_CONF_PRINTF_FLOAT_TO_STR_USE_FLOAT320=ON
        -DLLVM_CMAKE_DIR=${LLVM_BINARY_DIR}/lib/cmake/llvm
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
        -DLLVM_ENABLE_RUNTIMES=libc
        -DLLVM_LIBC_ALL_HEADERS=ON
        -DLLVM_LIBC_FULL_BUILD=ON
#         -DLIBC_TEST_LINK_OPTIONS_DEFAULT=-nostartfiles,-lsemihost,-T,llvmlibc.ld
#         -DLIBC_TEST_CMD=${test_cmd}
#         -DLIBC_TEST_HERMETIC_ONLY=true
        STEP_TARGETS configure build install
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE
        LIST_SEPARATOR ,
        CONFIGURE_HANDLED_BY_BUILD TRUE
        INSTALL_COMMAND ${CMAKE_COMMAND} --install .
        # Copy llvm-libc lib directory, moving libraries out of their
        # target-specific subdirectory.
        COMMAND
            ${CMAKE_COMMAND}
            -E copy_directory
            <INSTALL_DIR>/lib/${target_triple}
            "${TEMP_LIB_DIR}/lib"
        # Also copy the includes from their target-specific subdirectory.
        COMMAND
            ${CMAKE_COMMAND}
            -E copy_directory
            <INSTALL_DIR>/include/${target_triple}
            "${TEMP_LIB_DIR}/include"
    )

    # ExternalProject_Add(
    #     llvmlibc-support
    #     STAMP_DIR ${PROJECT_PREFIX}/llvmlibc-support/${VARIANT_BUILD_ID}/stamp
    #     BINARY_DIR ${PROJECT_PREFIX}/llvmlibc-support/${VARIANT_BUILD_ID}/build
    #     DOWNLOAD_DIR ${PROJECT_PREFIX}/llvmlibc-support/${VARIANT_BUILD_ID}/dl
    #     TMP_DIR ${PROJECT_PREFIX}/llvmlibc-support/${VARIANT_BUILD_ID}/tmp
    #     SOURCE_DIR ${TOOLCHAIN_SOURCE_DIR}/llvmlibc-support
    #     INSTALL_DIR ${TEMP_LIB_DIR}
    #     DEPENDS ${lib_tool_dependencies} llvmlibc-install
    #     CMAKE_ARGS
    #     ${compiler_launcher_cmake_args}
    #     ${common_llvmlibc_cmake_args}
    #     STEP_TARGETS build install
    #     USES_TERMINAL_CONFIGURE TRUE
    #     USES_TERMINAL_BUILD TRUE
    #     USES_TERMINAL_INSTALL TRUE
    #     USES_TERMINAL_TEST TRUE
    #     LIST_SEPARATOR ,
    #     CONFIGURE_HANDLED_BY_BUILD TRUE
    # )
endif()

add_dependencies(clib-configure ${C_LIBRARY}-configure)
add_dependencies(clib-build ${C_LIBRARY}-build)
add_dependencies(clib-install ${C_LIBRARY}-install)

###############################################################################
# runtimes (libcxx, libcxxabi, libunwind)
###############################################################################

if(ENABLE_CXX_LIBS)
    if(C_LIBRARY STREQUAL picolibc)
        set(cxxlibs_extra_cmake_options
            -DLIBCXXABI_ENABLE_THREADS=OFF
            -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF
            -DLIBCXX_ENABLE_RANDOM_DEVICE=OFF
            -DLIBCXX_ENABLE_THREADS=OFF
            -DLIBCXX_ENABLE_WIDE_CHARACTERS=OFF
            -DLIBUNWIND_ENABLE_THREADS=OFF
            -DLIBCXXABI_ENABLE_EXCEPTIONS=${ENABLE_EXCEPTIONS}
            -DLIBCXXABI_ENABLE_STATIC_UNWINDER=${ENABLE_EXCEPTIONS}
            -DLIBCXX_ENABLE_EXCEPTIONS=${ENABLE_EXCEPTIONS}
            -DLIBCXX_ENABLE_RTTI=${ENABLE_RTTI}
            -DRUNTIMES_USE_LIBC=picolibc
        )
    elseif(C_LIBRARY STREQUAL llvmlibc)
        set(cxxlibs_extra_cmake_options
            -DLIBCXXABI_ENABLE_THREADS=OFF
            -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF
            -DLIBCXX_ENABLE_RANDOM_DEVICE=OFF
            -DLIBCXX_ENABLE_THREADS=OFF
            -DLIBCXX_ENABLE_WIDE_CHARACTERS=OFF
            -DLIBCXX_ENABLE_FILESYSTEM=OFF
            -DLIBCXX_ENABLE_LOCALIZATION=ON
            -DLIBCXX_ENABLE_UNICODE=OFF
            -DLIBUNWIND_ENABLE_THREADS=OFF
            -DLIBCXXABI_ENABLE_EXCEPTIONS=${ENABLE_EXCEPTIONS}
            -DLIBCXXABI_ENABLE_STATIC_UNWINDER=${ENABLE_EXCEPTIONS}
            -DLIBCXX_ENABLE_EXCEPTIONS=${ENABLE_EXCEPTIONS}
            -DLIBCXX_ENABLE_RTTI=${ENABLE_RTTI}
            -DRUNTIMES_USE_LIBC=llvm-libc
            )
            set(lib_compile_flags "${lib_compile_flags} -D_LIBCPP_PRINT=1")
    elseif(C_LIBRARY MATCHES "^newlib")
        set(cxxlibs_extra_cmake_options
            -DLIBCXXABI_ENABLE_THREADS=OFF
            -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF
            -DLIBCXX_ENABLE_RANDOM_DEVICE=OFF
            -DLIBCXX_ENABLE_THREADS=OFF
            -DLIBUNWIND_ENABLE_THREADS=OFF
            -DLIBCXXABI_ENABLE_EXCEPTIONS=${ENABLE_EXCEPTIONS}
            -DLIBCXXABI_ENABLE_STATIC_UNWINDER=${ENABLE_EXCEPTIONS}
            -DLIBCXX_ENABLE_EXCEPTIONS=${ENABLE_EXCEPTIONS}
            -DLIBCXX_ENABLE_RTTI=${ENABLE_RTTI}
            -DRUNTIMES_USE_LIBC=newlib
        )

        if(C_LIBRARY STREQUAL newlib-nano)
            set(lib_compile_flags "${lib_compile_flags} -Oz")
        endif()

        if(C_LIBRARY STREQUAL newlib-nano)
            set(cxxlibs_extra_cmake_options
                ${cxxlibs_extra_cmake_options}
                -DLIBCXX_ENABLE_WIDE_CHARACTERS=OFF
            )
        else()
            set(cxxlibs_extra_cmake_options
                ${cxxlibs_extra_cmake_options}
                -DLIBCXX_ENABLE_WIDE_CHARACTERS=ON
            )
        endif()
    endif()

    ExternalProject_Add(
        cxxlibs
        STAMP_DIR ${PROJECT_PREFIX}/cxxlibs/${MULTILIB_DIR_def}/stamp
        BINARY_DIR ${PROJECT_PREFIX}/cxxlibs/${MULTILIB_DIR_def}/build
        DOWNLOAD_DIR ${PROJECT_PREFIX}/cxxlibs/${MULTILIB_DIR_def}/dl
        TMP_DIR ${PROJECT_PREFIX}/cxxlibs/${MULTILIB_DIR_def}/tmp
        SOURCE_DIR ${llvmproject_src_dir}/runtimes
        INSTALL_DIR ${TEMP_LIB_DIR}
        DEPENDS compiler_rt-install clib-install
        CMAKE_ARGS
        ${compiler_launcher_cmake_args}
        -DCMAKE_AR=${LLVM_BINARY_DIR}/bin/llvm-ar${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_ASM_FLAGS=${lib_compile_flags}
        -DCMAKE_BUILD_TYPE=${LIBRARY_CMAKE_BUILD_TYPE}
        -DCMAKE_CXX_COMPILER=${LLVM_BINARY_DIR}/bin/clang++${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_CXX_COMPILER_TARGET=${target_triple}
        -DCMAKE_CXX_FLAGS=${lib_compile_flags}
        -DCMAKE_C_COMPILER=${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_C_COMPILER_TARGET=${target_triple}
        -DCMAKE_C_FLAGS=${lib_compile_flags}
        -DCMAKE_INSTALL_MESSAGE=${CMAKE_INSTALL_MESSAGE}
        -DCMAKE_INSTALL_PREFIX=${TEMP_LIB_DIR}
        -DCMAKE_NM=${LLVM_BINARY_DIR}/bin/llvm-nm${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_RANLIB=${LLVM_BINARY_DIR}/bin/llvm-ranlib${CMAKE_EXECUTABLE_SUFFIX}
        # Let CMake know we're cross-compiling
        -DCMAKE_SYSTEM_NAME=Generic
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
        -DLIBCXXABI_BAREMETAL=ON
        -DLIBCXXABI_ENABLE_ASSERTIONS=OFF
        -DLIBCXXABI_ENABLE_SHARED=OFF
        -DLIBCXXABI_ENABLE_STATIC=ON
        -DLIBCXXABI_LIBCXX_INCLUDES="${TEMP_LIB_DIR}/include/c++/v1"
        -DLIBCXXABI_USE_COMPILER_RT=ON
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON
        -DLIBCXXABI_SHARED_OUTPUT_NAME="c++abi-shared"
        -DLIBCXX_ABI_UNSTABLE=ON
        -DLIBCXX_CXX_ABI=libcxxabi
        -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON
        -DLIBCXX_ENABLE_FILESYSTEM=OFF
        -DLIBCXX_ENABLE_SHARED=OFF
        -DLIBCXX_ENABLE_STATIC=ON
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF
        -DLIBCXX_SHARED_OUTPUT_NAME="c++-shared"
        -DLIBUNWIND_ENABLE_ASSERTIONS=OFF
        -DLIBUNWIND_ENABLE_SHARED=OFF
        -DLIBUNWIND_ENABLE_STATIC=ON
        -DLIBUNWIND_IS_BAREMETAL=ON
        -DLIBUNWIND_REMEMBER_HEAP_ALLOC=ON
        -DLIBUNWIND_USE_COMPILER_RT=ON
        -DLIBUNWIND_SHARED_OUTPUT_NAME="unwind-shared"
        -DLLVM_LIT_ARGS=${LLVM_LIT_ARGS}
        -DLLVM_ENABLE_RUNTIMES=libcxxabi,libcxx,libunwind
        ${cxxlibs_extra_cmake_options}
        ${cxxlibs_test_cmake_options}
        STEP_TARGETS configure build install
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE
        LIST_SEPARATOR ,
        CONFIGURE_HANDLED_BY_BUILD TRUE
    )
else() # if not ENABLE_CXX_LIBS

    # The parent riscv-multilib cmake script will still want to invoke
    # build targets like 'cxxlibs-configure', whether we actually have
    # C++ libraries or not. So we should define them, even if they
    # don't do anything.
    add_custom_target(cxxlibs-configure)
    add_custom_target(cxxlibs-build)
endif()

install(
    DIRECTORY ${TEMP_LIB_DIR}/
    DESTINATION .
)
