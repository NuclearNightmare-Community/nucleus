set(TARGET CoreNative)

configure_file(core_config.hpp.in ${CMAKE_CURRENT_BINARY_DIR}/core_config.hpp @ONLY)

# Mod Manager v2 story 2: Monocypher 4.0.2 (CC0-1.0 OR BSD-2-Clause; third_party/monocypher-4.0.2/README.md) for
# Ed25519 and BLAKE2b, which Windows CNG lacks. Two static builds of the two unmodified C files: one with the shared C
# runtime for core's DLL, one with the static C runtime for the catalog test exe.
set(MONOCYPHER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/monocypher-4.0.2/src)
set(MONOCYPHER_SRC ${MONOCYPHER_DIR}/monocypher.c ${MONOCYPHER_DIR}/optional/monocypher-ed25519.c)
add_library(CoreMonocypher STATIC ${MONOCYPHER_SRC})
target_include_directories(CoreMonocypher PUBLIC ${MONOCYPHER_DIR})
target_compile_options(CoreMonocypher PRIVATE /O2 /W3)
set_target_properties(CoreMonocypher PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
add_library(CoreMonocypherMT STATIC ${MONOCYPHER_SRC})
target_include_directories(CoreMonocypherMT PUBLIC ${MONOCYPHER_DIR})
target_compile_options(CoreMonocypherMT PRIVATE /O2 /W3)
set_target_properties(CoreMonocypherMT PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded")
# The catalog's code (JSON, minisign, the verify.ps1 port, fetching), shared by core's DLL and the test exe.
set(CATALOG_SRC catalog/json.cpp catalog/minisig.cpp catalog/verify.cpp catalog/fetch.cpp)
# Mod Manager v2 story 3: staged changes (the plan, the layout and targets, SHA-256 through CNG; the apply engine),
# shared by core's DLL (status, start, ack) and the relaunch helper (which applies). Windows and the C++ library only.
set(STAGE_SRC stage/plan.cpp stage/apply.cpp)

add_library(${TARGET} SHARED dllmain.cpp core_shared.cpp objectives.cpp intercept.cpp restart.cpp apply.cpp catalog.cpp ${CATALOG_SRC} ${STAGE_SRC})
target_include_directories(${TARGET} PRIVATE . ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(${TARGET} PUBLIC UE4SS)
target_link_libraries(${TARGET} PRIVATE CoreMonocypher winhttp bcrypt crypt32)
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
# Mod Manager v2 story 3: it also applies staged changes (stage/), hashing with CNG (bcrypt).
add_executable(${RESTART_TARGET} WIN32 restart_helper.cpp ${STAGE_SRC})
target_include_directories(${RESTART_TARGET} PRIVATE . ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(${RESTART_TARGET} PRIVATE UNICODE _UNICODE)
set_target_properties(${RESTART_TARGET} PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded" CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_link_libraries(${RESTART_TARGET} PRIVATE shell32 ole32 bcrypt)
target_link_options(${RESTART_TARGET} PRIVATE "/PDBALTPATH:%_PDB%")

# Its test build <name>RestartTest.exe (native/test/restart-helper.tests.ps1, never packaged): a console program with
# CORE_RESTART_TEST (--record instead of launching, --timeout-ms, --probe-mode; apply mode: --root, --fail-after,
# --crash-after for native/test/apply.tests.ps1).
set(RESTART_TEST_TARGET ${CORE_NAME}RestartTest)
add_executable(${RESTART_TEST_TARGET} restart_helper.cpp ${STAGE_SRC})
target_include_directories(${RESTART_TEST_TARGET} PRIVATE . ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(${RESTART_TEST_TARGET} PRIVATE UNICODE _UNICODE CORE_RESTART_TEST=1)
set_target_properties(${RESTART_TEST_TARGET} PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded" CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_link_libraries(${RESTART_TEST_TARGET} PRIVATE shell32 ole32 bcrypt)
target_link_options(${RESTART_TEST_TARGET} PRIVATE "/PDBALTPATH:%_PDB%")

# Mod Manager v2 story 2: <name>CatalogTest.exe (native/test/catalog.tests.ps1, never packaged), a console program with
# CORE_CATALOG_TEST: verify.ps1's parameters and output over core's catalog code, plus a named proxy and a pinned server
# certificate for the local HTTPS fixture server. Windows system libraries and the static C runtime only, never UE4SS.
set(CATALOG_TEST_TARGET ${CORE_NAME}CatalogTest)
add_executable(${CATALOG_TEST_TARGET} catalog_cli.cpp ${CATALOG_SRC})
target_include_directories(${CATALOG_TEST_TARGET} PRIVATE . ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(${CATALOG_TEST_TARGET} PRIVATE UNICODE _UNICODE CORE_CATALOG_TEST=1)
target_compile_options(${CATALOG_TEST_TARGET} PRIVATE /O2 /utf-8)
set_target_properties(${CATALOG_TEST_TARGET} PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded" CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_link_libraries(${CATALOG_TEST_TARGET} PRIVATE CoreMonocypherMT winhttp bcrypt crypt32)
target_link_options(${CATALOG_TEST_TARGET} PRIVATE "/PDBALTPATH:%_PDB%")
