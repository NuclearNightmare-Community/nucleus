<#
.SYNOPSIS
  Offline test of build.ps1's package refusal (Mod Manager v2 story 6): the package step refuses a main.dll that
  carries the test flavour's marker (catalog.cpp k_test_marker). Reads build.ps1's own marker and Test-HasMarker
  (parsed, not run: nothing is built and build/ is never touched) and checks them against temp files.
.EXAMPLE
  pwsh -NoProfile -File test/unit/package_marker_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}

$build = Join-Path $repo 'build.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($build, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-HasMarker' }, $true)
$asg = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$testMarker' }, $true)
Ok ($null -ne $fn) 'build.ps1 defines Test-HasMarker'
Ok ($null -ne $asg) 'build.ps1 sets $testMarker'
$native = Get-Content -Raw (Join-Path $repo 'native\src\catalog.cpp')
$want = if ($native -match 'k_test_marker\s*(\[\])?\s*=\s*"([^"]+)"') { $Matches[2] } else { $null }
Ok ($null -ne $want) 'catalog.cpp defines k_test_marker'
if ($fn -and $asg) {
    # build.ps1's own text (parsed above), evaluated here: the marker's value, then the function dot-sourced into scope
    $testMarker = & ([scriptblock]::Create($asg.Right.Extent.Text))
    Ok ($testMarker -ceq $want) "build.ps1's marker equals catalog.cpp's" "$testMarker vs $want"
    . ([scriptblock]::Create($fn.Extent.Text))
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "nucleus-marker-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $with = Join-Path $tmp 'with.dll'; $without = Join-Path $tmp 'without.dll'
        [IO.File]::WriteAllBytes($with, [byte[]](@(0x4D, 0x5A, 0, 1) + [Text.Encoding]::ASCII.GetBytes("xx$($want)yy") + @(0, 2)))
        [IO.File]::WriteAllBytes($without, [byte[]](@(0x4D, 0x5A, 0, 1) + [Text.Encoding]::ASCII.GetBytes('NN-CORE-CATALOG-TEST-BUILD') + @(0, 2)))
        Ok (Test-HasMarker $with) 'a file holding the marker is flagged'
        Ok (-not (Test-HasMarker $without)) 'a file without the marker is not flagged'
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
# The package step itself refuses: a throw guarded by Test-HasMarker on the packaged main.dll.
$pkgGuard = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -match "Test-HasMarker\s+\`$parts\['main\.dll'\]" -and $n.Clauses[0].Item2.Extent.Text -match '\bthrow\b' }, $true)
Ok ($null -ne $pkgGuard) "the package step throws when Test-HasMarker flags `$parts['main.dll']"

Write-Host "package_marker_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
