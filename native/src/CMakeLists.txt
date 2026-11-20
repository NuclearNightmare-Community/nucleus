set(TARGET CoreNative)

configure_file(core_config.hpp.in ${CMAKE_CURRENT_BINARY_DIR}/core_config.hpp @ONLY)
add_library(${TARGET} SHARED dllmain.cpp core_shared.cpp objectives.cpp intercept.cpp restart.cpp)
target_include_directories(${TARGET} PRIVATE . ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(${TARGET} PUBLIC UE4SS)
# Record only the PDB's file name in the DLL, not the absolute build path (which contains the Windows user name).
target_link_options(${TARGET} PRIVATE "/PDBALTPATH:%_PDB%")

# Core's test-only DLL (test/SkelNative, never shipped): core's objectives code built with CORE_OBJECTIVES_TEST, for the
# bad-input scenario's forced missing struct member.
set(TEST_TARGET CoreNativeTest)
add_library(${TEST_TARGET} SHARED ${CMAKE_CURRENT_SOURCE_DIR}/../../test/SkelNative/skel_native.cpp core_shared.cpp objectives.cpp)
target_include_directories(${TEST_TARGET} PRIVATE . ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(${TEST_TARGET} PRIVATE CORE_OBJECTIVES_TEST=1)
target_link_libraries(${TEST_TARGET} PUBLIC UE4SS)
target_link_options(${TEST_TARGET} PRIVATE "/PDBALTPATH:%_PDB%")

# Core story 45 (Mod Manager story 8): the relaunch helper <name>Restart.exe (packaged as Mods/<name>/bin/). A GUI
# program (no window, no console) linking only Windows system libraries and the static C runtime, never UE4SS.
set(RESTART_TARGET ${CORE_NAME}Restart)
add_executable(${RESTART_TARGET} WIN32 restart_helper.cpp)
target_compile_definitions(${RESTART_TARGET} PRIVATE UNICODE _UNICODE)
set_target_properties(${RESTART_TARGET} PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded" CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_link_libraries(${RESTART_TARGET} PRIVATE shell32 ole32)
target_link_options(${RESTART_TARGET} PRIVATE "/PDBALTPATH:%_PDB%")

# Its test build <name>RestartTest.exe (native/test/restart-helper.tests.ps1, never packaged): a console program with
# CORE_RESTART_TEST (--record instead of launching, --timeout-ms, --probe-mode).
set(RESTART_TEST_TARGET ${CORE_NAME}RestartTest)
add_executable(${RESTART_TEST_TARGET} restart_helper.cpp)
target_compile_definitions(${RESTART_TEST_TARGET} PRIVATE UNICODE _UNICODE CORE_RESTART_TEST=1)
set_target_properties(${RESTART_TEST_TARGET} PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded" CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_link_libraries(${RESTART_TEST_TARGET} PRIVATE shell32 ole32)
target_link_options(${RESTART_TEST_TARGET} PRIVATE "/PDBALTPATH:%_PDB%")
