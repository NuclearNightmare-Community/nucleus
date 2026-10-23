# Core's native part, laid out as the pinned UE4SS commit's guide describes (docs/guides/creating-a-c++-mod.md):
# UE4SS as a subdirectory, then the mod. Configure through build.ps1, which sets up VS 2026, the build mode and
# UE4SS_SRC, CORE_NAME and CORE_VERSION (from mod.json).
cmake_minimum_required(VERSION 3.22)
project(CoreNativeWorkspace)

set(UE4SS_SRC "" CACHE PATH "UE4SS source checkout at the pinned commit (with submodules)")
set(CORE_NAME "" CACHE STRING "Core's name (mod.json name)")
set(CORE_VERSION "" CACHE STRING "Core's version (mod.json version)")
if(NOT EXISTS "${UE4SS_SRC}/CMakeLists.txt")
    message(FATAL_ERROR "UE4SS_SRC is not a UE4SS checkout: ${UE4SS_SRC}")
endif()
if(CORE_NAME STREQUAL "" OR CORE_VERSION STREQUAL "")
    message(FATAL_ERROR "CORE_NAME and CORE_VERSION must be set (build.ps1 reads them from mod.json)")
endif()

add_subdirectory(${UE4SS_SRC} ue4ss)
add_subdirectory(src)
