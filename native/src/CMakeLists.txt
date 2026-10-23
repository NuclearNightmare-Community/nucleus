set(TARGET CoreNative)

configure_file(core_config.hpp.in ${CMAKE_CURRENT_BINARY_DIR}/core_config.hpp @ONLY)
add_library(${TARGET} SHARED dllmain.cpp)
target_include_directories(${TARGET} PRIVATE . ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(${TARGET} PUBLIC UE4SS)
# Record only the PDB's file name in the DLL, not the absolute build path (which contains the Windows user name).
target_link_options(${TARGET} PRIVATE "/PDBALTPATH:%_PDB%")
