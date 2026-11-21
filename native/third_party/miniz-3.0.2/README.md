# miniz 3.0.2 (vendored)

Raw Deflate inflate (`tinfl_decompress`) and CRC-32 (`mz_crc32`) for core's zip reader (Mod Manager v2 story 5: `native/src/stage/zip.cpp`). Release zips are Deflate, and Windows has no raw-inflate API (its Compression API's MSZIP adds its own framing). The zip parsing itself is core's own code, so every bound is core's.

- Source: https://github.com/richgel999/miniz/releases/download/3.0.2/miniz-3.0.2.zip (the amalgamated release, tag 3.0.2)
- Zip SHA-256: `ada38db0b703a56d3dd6d57bf84a9c5d664921d870d8fea4db153979fb5332c5` (downloaded 2026-11-21)
- Files, unmodified from the zip: `miniz.c`, `miniz.h`, `LICENSE`
- Licence: MIT (`LICENSE`; Rich Geldreich, RAD Game Tools, Valve Software). The package ships `LICENSE` as `Mods/Nucleus/LICENSES/miniz.txt`, because `main.dll` contains the compiled code.

Built by `native/src/CMakeLists.txt` as two small static libraries (`CoreMiniz` for `main.dll`, `CoreMinizMT` for the catalog test exe) with `MINIZ_NO_STDIO`, `MINIZ_NO_TIME`, `MINIZ_NO_ARCHIVE_APIS` and `MINIZ_NO_ZLIB_COMPATIBLE_NAMES`. Core calls only `tinfl_decompress` and `mz_crc32`. To update: download the new release, check its hash, replace the three files, and record the new version and hash here.
