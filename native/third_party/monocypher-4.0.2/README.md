# Monocypher 4.0.2 (vendored)

Ed25519 (with SHA-512) and BLAKE2b for core's catalog verification (Mod Manager v2 story 2): minisign's `Ed` and `ED` signatures. Windows CNG has no Ed25519; SHA-256 comes from CNG.

- Source: https://monocypher.org/download/monocypher-4.0.2.tar.gz (the same file is attached to https://github.com/LoupVaillant/Monocypher/releases/tag/4.0.2)
- Tarball SHA-256: `38d07179738c0c90677dba3ceb7a7b8496bcfea758ba1a53e803fed30ae0879c` (both downloads, 2026-11-20)
- Files, unmodified from the tarball: `src/monocypher.c`, `src/monocypher.h`, `src/optional/monocypher-ed25519.c`, `src/optional/monocypher-ed25519.h`, `LICENCE.md`
- Licence: CC0-1.0 OR BSD-2-Clause (`LICENCE.md`). The package ships `LICENCE.md` as `Mods/Nucleus/LICENSES/monocypher.txt`, because `main.dll` contains the compiled code.

Built by `native/src/CMakeLists.txt` as two small static libraries (`CoreMonocypher` for `main.dll`, `CoreMonocypherMT` for the catalog test exe). To update: download the new release, check its hash against both sources, replace the five files, and record the new version and hash here.
