# To avoid duplicating the FetchContent code, this file can be
# included by either the top-level toolchain cmake, or the
# arm-runtimes sub-project.
# FETCHCONTENT_SOURCE_DIR_NEWLIB should be passed down from the
# top level to any library builss to prevent repeated checkouts.

include(FetchContent)
include(${CMAKE_CURRENT_LIST_DIR}/patch_repo.cmake)

set(newlib_URL "https://sourceware.org/git/newlib-cygwin.git")
set(newlib_TAG "newlib-4.5.0")
# "commithash"
#     # GIT_SHALLOW doesn't work with commit hashes.
#     set(shallow OFF)
# "branch"
#     set(shallow ON)
#     # CMake docs recommend that "branch names and tags should
#     # generally be specified as remote names"
#     set(tag "origin/${tag}")
# "tag"
#     set(shallow ON)
set(newlib_SHALLOW ON)
get_patch_command(${CMAKE_CURRENT_LIST_DIR}/.. newlib newlib_patch_command)
FetchContent_Declare(newlib
    GIT_REPOSITORY "${newlib_URL}"
    GIT_TAG "${newlib_TAG}"
    GIT_SHALLOW "${newlib_SHALLOW}"
    GIT_PROGRESS TRUE
    PATCH_COMMAND ${newlib_patch_command}
    # We don't do the configuration here.
    SOURCE_SUBDIR do_not_add_newlib_subdir
)
FetchContent_MakeAvailable(newlib)
FetchContent_GetProperties(newlib SOURCE_DIR FETCHCONTENT_SOURCE_DIR_NEWLIB)
