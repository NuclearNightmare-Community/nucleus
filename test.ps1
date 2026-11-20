<#
.SYNOPSIS
  Runs Nucleus's unit tests, no game needed: every test/unit/*_test.lua (core's pure modules and its UI, map, net,
  settings and restart code against stubbed UE4SS and game objects) and every test/unit/*_test.ps1 (run.ps1's run
  guard). The C++ tests, the Blueprint cook and the in-game scenarios are not unit tests (README.md).
  Lua: the first of lua, lua5.4, lua54, lua5.3, texlua (MiKTeX's texlua.exe is Lua 5.3) found on PATH; -Lua picks one.
.EXAMPLE
  ./test.ps1
  ./test.ps1 -Only lua
#>
param([string] $Lua, [ValidateSet('all', 'lua', 'ps')] [string] $Only = 'all')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Lua) { $Lua = @('lua', 'lua5.4', 'lua54', 'lua5.3', 'texlua') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1 }
$failed = @()
Push-Location $here
try {
    if ($Only -in 'all', 'lua') {
        if (-not $Lua) { Write-Host 'FAIL: no Lua 5.3/5.4 interpreter on PATH (lua, texlua, ...); pass -Lua'; $failed += 'lua' }
        else {
            foreach ($t in Get-ChildItem -LiteralPath 'test/unit' -Filter '*_test.lua' | Sort-Object Name) {
                # texlua prints a MiKTeX update reminder on stderr; only the test's own output matters.
                $out = & $Lua "test/unit/$($t.Name)" 2>$null
                $code = $LASTEXITCODE
                $out | ForEach-Object { Write-Host $_ }
                if ($code -ne 0) { $failed += $t.BaseName }
            }
        }
    }
    if ($Only -in 'all', 'ps') {
        foreach ($t in Get-ChildItem -LiteralPath 'test/unit' -Filter '*_test.ps1' | Sort-Object Name) {
            & pwsh -NoProfile -NonInteractive -File "test/unit/$($t.Name)"
            if ($LASTEXITCODE -ne 0) { $failed += $t.BaseName }
        }
    }
} finally { Pop-Location }
if ($failed) { Write-Host "Unit tests failed: $($failed -join ', ')"; exit 1 }
Write-Host 'All unit tests passed.'
