#
# Copyright (c) 2024-2025, Arm Limited and affiliates.
#
# Part of the Arm Toolchain project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#
# Copyright (c) 2025, Laurent von Allmen.
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
cmake_path(GET TOOLCHAIN_SOURCE_DIR PARENT_PATH llvm_parent1)
cmake_path(GET llvm_parent1 PARENT_PATH llvmproject_src_dir)

set(VARIANT_JSON "" CACHE STRING "JSON file to load args from.")
if(VARIANT_JSON)
    file(READ ${VARIANT_JSON} variant_json_read)
    # Load arguments common to all libraries.
    # "TARGET_ARCH":
    # "VARIANT":
    # "COMPILE_FLAGS":
    # "ENABLE_EXCEPTIONS":
    # "ENABLE_RTTI":
    # "LIBRARY_BUILD_TYPE":
    # "MULTILIB_DIR":

    # Load arguments specific to the chosen library, overwriting any existing values.
    string(JSON json_args GET ${variant_json_read} "args" "common")
    string(JSON json_args_len LENGTH ${json_args})
    math(EXPR json_args_len_dec "${json_args_len} - 1")
    foreach(json_idx RANGE ${json_args_len_dec})
        string(JSON json_param MEMBER ${json_args} ${json_idx})
        string(JSON json_val GET ${json_args} ${json_param})
        string(JSON json_val_type TYPE ${json_args} ${json_param})
        set(${json_param}_def ${json_val})
    endforeach()
    set(ENABLE_CXX_LIBS_def OFF)
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

set(SUPPORTED_LIBRARY_BUILD_TYPES minsizerelease release)
if(NOT LIBRARY_BUILD_TYPE_def IN_LIST SUPPORTED_LIBRARY_BUILD_TYPES)
    message(FATAL_ERROR "Unsupported LIBRARY_BUILD_TYPE value. Supported values are: minsizerelease, release.")
endif()
set(LIBRARY_BUILD_TYPE ${LIBRARY_BUILD_TYPE_def} CACHE STRING "Build type to use in library builds.")
set_property(CACHE LIBRARY_BUILD_TYPE PROPERTY STRINGS ${SUPPORTED_LIBRARY_BUILD_TYPES})

set(ENABLE_CXX_LIBS ${ENABLE_CXX_LIBS_def} CACHE BOOL "Build CXX libs")
set(LLVM_BINARY_DIR "" CACHE PATH "Path to LLVM toolchain root to build libraries with")

set(PROJECT_PREFIX "subproj" CACHE STRING "Directory to build subprojects in.")

# Temporary location to collect the libraries as they are built.
# CMAKE_CURRENT_BINARY_DIR is the path defined by the BINARY_DIR of ExternalProject_Add
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

set(compile_arch_flags "${COMPILE_FLAGS} --sysroot ${TEMP_LIB_DIR}")
# Compiling the libraries benefits from some extra optimization
# flags, and requires a sysroot.
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

ExternalProject_Add(
    compiler_rt
    STAMP_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/stamp
    BINARY_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/build
    DOWNLOAD_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/dl
    TMP_DIR ${PROJECT_PREFIX}/compiler_rt/${MULTILIB_DIR_def}/tmp
    SOURCE_DIR ${llvmproject_src_dir}/runtimes
    INSTALL_DIR compiler-rt/install
    CMAKE_ARGS
    ${compiler_launcher_cmake_args}
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
    -DCOMPILER_RT_BUILD_PROFILE=OFF
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF
    -DCOMPILER_RT_BUILD_XRAY=OFF
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
    -DLLVM_ENABLE_RUNTIMES=compiler-rt
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
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

###############################################################################
# newlib
###############################################################################

set(newlib_options
    --enable-newlib-io-long-long
    --enable-newlib-register-fini
    --disable-newlib-supplied-syscalls
    --enable-newlib-io-c99-formats
    --disable-nls
    --enable-lite-exit
    --disable-multilib
    --enable-newlib-retargetable-locking
    --enable-newlib-io-float)
set(newlib_optim_flags
    "-O2")

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
    "CFLAGS_FOR_TARGET=${flags} ${newlib_optim_flags} ${lib_compile_flags} -Wno-error=implicit-function-declaration -D__USES_INITFINI__ -U_HAVE_INIT_FINI -Wno-unknown-pragmas -Qunused-arguments"
    "CCASFLAGS=${flags} ${newlib_optim_flags} ${lib_compile_flags} -Wno-error=implicit-function-declaration -D__USES_INITFINI__ -U_HAVE_INIT_FINI -Wno-unknown-pragmas -Qunused-arguments"
)
execute_process(
    COMMAND ${LLVM_BINARY_DIR}/bin/clang -target ${target_triple} -print-multi-lib
    RESULT_VARIABLE clang_result
    OUTPUT_VARIABLE multi_libs
    ERROR_VARIABLE clang_stderr
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

include(ProcessorCount)
set(make_flags)
ProcessorCount(nproc)
if(NOT nproc EQUAL 0)
    set(make_flags -j${nproc})
endif()

ExternalProject_Add(
    newlib
    STAMP_DIR ${PROJECT_PREFIX}/newlib/${MULTILIB_DIR_def}/stamp
    BINARY_DIR ${PROJECT_PREFIX}/newlib/${MULTILIB_DIR_def}/build
    DOWNLOAD_DIR ${PROJECT_PREFIX}/newlib/${MULTILIB_DIR_def}/dl
    TMP_DIR ${PROJECT_PREFIX}/newlib/${MULTILIB_DIR_def}/tmp
    SOURCE_DIR ${newlib_SOURCE_DIR}
    INSTALL_DIR ${TEMP_LIB_DIR}
    CONFIGURE_COMMAND
        ${CMAKE_COMMAND} -E env ${build_env}
        <SOURCE_DIR>/configure
        --target=${target_triple}
        --prefix "${TEMP_LIB_DIR}"
        --exec_prefix <BINARY_DIR>/tmpinstall
        ${newlib_options}
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


add_dependencies(clib-configure newlib-configure)
add_dependencies(clib-build newlib-build)
add_dependencies(clib-install newlib-install)

###############################################################################
# runtimes (libcxx, libcxxabi, libunwind)
###############################################################################

if(ENABLE_CXX_LIBS)
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
    )

    set(cxxlibs_extra_cmake_options
        ${cxxlibs_extra_cmake_options}
        -DLIBCXX_ENABLE_WIDE_CHARACTERS=ON
    )

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
