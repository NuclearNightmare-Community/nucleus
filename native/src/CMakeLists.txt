set(TARGET CoreNative)

configure_file(core_config.hpp.in ${CMAKE_CURRENT_BINARY_DIR}/core_config.hpp @ONLY)
add_library(${TARGET} SHARED dllmain.cpp core_shared.cpp objectives.cpp)
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
