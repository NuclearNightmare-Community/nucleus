<#
.SYNOPSIS
  Tests core's native catalog code (Mod Manager v2 story 2) through its console test build, without the game and
  without the live catalog.
.DESCRIPTION
  Drives build/native-out/test/<name>CatalogTest.exe (CORE_CATALOG_TEST; build.ps1's native step makes it):
    - the workspace's verify.ps1 fixture runners with -Verifier: tools/release/tests/run-tests.ps1 (every fixture
      decided as verify.ps1 decides it; only trust: embedded cases may show SKIP) and run-fetch-tests.ps1 (every fetch
      scenario over real HTTPS through the local fixture server, https-fixture-server.ps1)
    - the shared mod id cases (tools/release/tests/modid-cases.json) through -ModId (string inputs without a NUL byte;
      the others can't be passed on a command line)
    - -PrintBuiltIns equals verify.ps1's $BuiltInKeys, $BuiltInPrimary, $BuiltInFallback and $RedirectHosts
    - release-file downloads (-Download, the code <Core>_CatalogDownload runs), served by the fixture server: ok (and
      again: already downloaded), a redirect to objects.githubusercontent.com, truncated, grown, one byte changed, a
      redirect to another host, 6 redirects, unknown id or version, a revoked version (either action), an index size
      over 256 MiB, a downloads folder that would pass 512 MiB; after a failure nothing is left in the folder
    - bounds: an index nested 65 deep is invalid-index; an unpinned certificate (the fixture server's, without
      -PinCert, so Windows' own checks apply) makes every base unreachable
  Prints ok:/FAIL: lines and exits 1 on any failure. Needs minisign on PATH (winget install jedisct1.minisign) and this
  workspace; under NN_CI=1 it skips (the CI has neither the build nor the workspace).
.EXAMPLE
  pwsh -NoProfile -File native/test/catalog.tests.ps1
#>
param([string] $TestExe, [string] $Minisign)
$ErrorActionPreference = 'Stop'
if ($env:NN_CI -eq '1') { Write-Host 'SKIP: catalog.tests.ps1 needs the native build and the workspace (NN_CI=1)'; exit 0 }
$repo = Split-Path (Split-Path $PSScriptRoot)
$name = (Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json).name
if (-not $TestExe) { $TestExe = Join-Path $repo "build\native-out\test\$($name)CatalogTest.exe" }
if (-not (Test-Path -LiteralPath $TestExe)) { Write-Host "FAIL: $TestExe not found; run build.ps1 -Steps native first"; exit 1 }
$TestExe = (Resolve-Path -LiteralPath $TestExe).Path
$ws = $repo
while ($ws -and -not (Test-Path (Join-Path $ws 'tools\launch.ps1'))) { $ws = Split-Path $ws }
if (-not $ws) { Write-Host 'FAIL: the workspace (with tools/launch.ps1) was not found above this repo'; exit 1 }
$tests = Join-Path $ws 'tools\release\tests'
$verifyPs1 = Join-Path $ws 'tools\release\verify.ps1'
if (-not $Minisign) {
    $cmd = Get-Command minisign -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Write-Host 'FAIL: minisign not found on PATH (winget install jedisct1.minisign); or pass -Minisign'; exit 1 }
    $Minisign = $cmd.Source
}
$pwsh = (Get-Process -Id $PID).Path

$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $label, $detail) {
    if ($cond) { $script:passed++; Write-Host "ok:   $label" } else { $script:failed++; Write-Host "FAIL: $label$(if ($null -ne $detail) { " -- $detail" })" }
}
function Run-Exe { $script:out = @(& $TestExe @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE }
function Outcome { if ($script:out.Count) { $script:out[0] } else { '' } }
function Has-Line([string] $text) { [bool]($script:out | Where-Object { $_.Contains($text) }) }
function Shown { ($script:out | Select-Object -First 12) -join ' | ' }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "$name-catalog-$PID"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$server = $null
try {
    # ---------------------------------------------------------------- verify.ps1's fixture runners
    foreach ($runner in 'run-tests.ps1', 'run-fetch-tests.ps1') {
        $lines = @(& $pwsh -NoProfile -NonInteractive -File (Join-Path $tests $runner) -Verifier $TestExe -Minisign $Minisign 2>&1 | ForEach-Object { "$_" })
        $rc = $LASTEXITCODE
        $fails = @($lines | Where-Object { $_ -like 'FAIL *' })
        $skips = @($lines | Where-Object { $_ -like 'SKIP *' })
        $badSkips = @($skips | Where-Object { $_ -notlike '*(trust: embedded*' })
        $summary = $lines | Where-Object { $_ -match '^\d+/\d+ passed' } | Select-Object -Last 1
        Ok ($rc -eq 0 -and -not $fails -and -not $badSkips) "$runner -Verifier: every case passes ($summary)" "exit $rc; $($fails -join '; ')$($badSkips -join '; ')"
        if ($fails) { $lines | Where-Object { $_ -like '     *' } | Select-Object -First 40 | ForEach-Object { Write-Host "      $_" } }
    }

    # ---------------------------------------------------------------- the mod id normalizer's shared cases
    $cases = (Get-Content (Join-Path $tests 'modid-cases.json') -Raw | ConvertFrom-Json).cases
    $checked = 0; $wrong = @()
    foreach ($c in $cases) {
        if ($c.input -isnot [string] -or $c.input.Contains([char]0)) { continue }
        Run-Exe -ModId $c.input
        $want = if ($null -ne $c.id) { "id: $($c.id)" } else { "error: $($c.error)" }
        if ($script:out[0] -cne $want) { $wrong += "$($c.name): got '$($script:out[0])', want '$want'" }
        $checked++
    }
    Ok ($checked -ge 35 -and -not $wrong) "modid-cases.json: $checked string cases normalize as in verify.ps1" ($wrong -join '; ')

    # ---------------------------------------------------------------- built-ins equal verify.ps1's
    $src = Get-Content -LiteralPath $verifyPs1 -Raw
    $want = @()
    foreach ($m in [regex]::Matches($src, "(?m)^\s*@\{ role = '([a-z]+)'; name = '([^']+)'; key = '([^']+)' \}")) { $want += "key: $($m.Groups[1].Value) $($m.Groups[2].Value) $($m.Groups[3].Value)" }
    $want += 'primary: ' + [regex]::Match($src, "(?m)^\`$BuiltInPrimary = '([^']+)'").Groups[1].Value
    $want += 'fallback: ' + [regex]::Match($src, "(?m)^\`$BuiltInFallback = '([^']+)'").Groups[1].Value
    foreach ($h in ([regex]::Match($src, "(?m)^\`$RedirectHosts = (.+)$").Groups[1].Value -split ',')) { $want += "redirect: $($h.Trim().Trim("'"))" }
    Run-Exe -PrintBuiltIns
    Ok (($script:out -join "`n") -ceq ($want -join "`n") -and $want.Count -eq 8) 'built-in keys, endpoints and redirect hosts equal verify.ps1''s' "got [$($script:out -join ', ')] want [$($want -join ', ')]"

    # ---------------------------------------------------------------- keys, a signed catalog, the fixture server
    $keys = @{}
    foreach ($role in 'release', 'backup', 'revoke') {
        $pub = Join-Path $tmp "$role.pub"; $sec = Join-Path $tmp "$role.key"
        $null = & $Minisign -G -W -p $pub -s $sec 2>&1
        if ($LASTEXITCODE) { throw "minisign -G failed for $role" }
        $keys[$role] = @{ Pub = (Get-Content $pub)[1].Trim(); Sec = $sec }
    }
    $trustFile = Join-Path $tmp 'trusted-keys.json'
    ConvertTo-Json @(foreach ($role in 'release', 'backup', 'revoke') { [ordered]@{ role = $role; name = "fixture-$role"; key = $keys[$role].Pub } }) |
        Set-Content -LiteralPath $trustFile -Encoding utf8NoBOM
    function Sign([string] $file, [string] $role) {
        $o = & $Minisign -S -s $keys[$role].Sec -m $file -t 'catalog.tests' 2>&1
        if ($LASTEXITCODE) { throw "minisign -S failed: $o" }
    }
    $bytes = [byte[]]::new(8192)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = ($i * 7) % 251 }
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $site = Join-Path $tmp 'site'
    New-Item -ItemType Directory -Force $site | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $site 'ok.zip'), $bytes)
    [IO.File]::WriteAllBytes((Join-Path $site 'short.zip'), $bytes[0..($bytes.Length - 2)])
    [IO.File]::WriteAllBytes((Join-Path $site 'long.zip'), [byte[]]($bytes + [byte]0))
    $flip = [byte[]]$bytes.Clone(); $flip[4000] = $flip[4000] -bxor 0xFF
    [IO.File]::WriteAllBytes((Join-Path $site 'flip.zip'), $flip)
    $repo2 = 'NuclearNightmare-Community/markers'
    function Ver([string] $v, [long] $size = $bytes.Length, [string] $sha256 = $sha) {
        [ordered]@{ version = $v; scope = 'client'; url = "https://github.com/$repo2/releases/download/v$v/markers-$v.zip"; sha256 = $sha256; size = $size; published = '2026-11-20T10:00:00Z' }
    }
    $versions = @((Ver '0.1.0'), (Ver '0.1.1'), (Ver '0.1.2'), (Ver '0.1.3'), (Ver '0.1.4'), (Ver '0.1.5'), (Ver '0.1.6'), (Ver '0.1.7'), (Ver '0.1.8'), (Ver '0.1.9'), (Ver '0.2.0' -size 300MB), (Ver '0.3.0'), (Ver '0.3.1'))
    $ix = [ordered]@{ schema = 2; serial = 5; issued = '2026-11-20T10:00:00Z'; packages = @([ordered]@{
                id = 'nuclearnightmare-community.markers'; name = 'Markers'; description = 'Shared map markers.'; categories = @('qol'); kind = 'mod'
                publisher = 'NuclearNightmare-Community'; repo = $repo2; versions = $versions }) }
    $ixFile = Join-Path $tmp 'index.json'
    $ix | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $ixFile -Encoding utf8NoBOM
    Sign $ixFile 'release'
    $rv = [ordered]@{ schema = 1; serial = 1; issued = '2026-11-20T10:00:00Z'; revoked = @(
            [ordered]@{ id = 'NuclearNightmare-Community.Markers'; version = '0.3.0'; sha256 = $sha.ToUpperInvariant(); reason = 'crash on map load'; action = 'disable' },
            [ordered]@{ id = 'nuclearnightmare-community.markers'; version = '0.3.1'; sha256 = $sha; reason = 'bad build'; action = 'block' }) }
    $rvFile = Join-Path $tmp 'revoked.json'
    $rv | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $rvFile -Encoding utf8NoBOM
    Sign $rvFile 'revoke'

    $gh = "https://github.com/$repo2/releases/download"
    $obj = 'https://objects.githubusercontent.com/x'
    $map = [ordered]@{
        "$gh/v0.1.0/markers-0.1.0.zip" = @{ status = 200; file = 'site/ok.zip' }
        "$gh/v0.1.1/markers-0.1.1.zip" = @{ status = 302; location = "$obj/m011" }
        "$obj/m011"                    = @{ status = 200; file = 'site/ok.zip' }
        "$gh/v0.1.2/markers-0.1.2.zip" = @{ status = 200; file = 'site/short.zip' }
        "$gh/v0.1.3/markers-0.1.3.zip" = @{ status = 200; file = 'site/long.zip' }
        "$gh/v0.1.4/markers-0.1.4.zip" = @{ status = 200; file = 'site/flip.zip' }
        "$gh/v0.1.5/markers-0.1.5.zip" = @{ status = 302; location = 'https://evil.example/m.zip' }
        'https://evil.example/m.zip'   = @{ status = 200; file = 'site/ok.zip' }
        "$gh/v0.1.6/markers-0.1.6.zip" = @{ status = 302; location = "$obj/r1" }
        "$gh/v0.1.7/markers-0.1.7.zip" = @{ status = 503 }
    }
    # 0.1.6: exactly 6 redirects (gh, r1..r5); 0.1.8: exactly 5 (gh, s1..s4), the most that is followed.
    for ($i = 1; $i -le 5; $i++) { $map["$obj/r$i"] = @{ status = 302; location = "$obj/r$($i + 1)" } }
    $map["$obj/r6"] = @{ status = 200; file = 'site/ok.zip' }
    $map["$gh/v0.1.8/markers-0.1.8.zip"] = @{ status = 302; location = "$obj/s1" }
    for ($i = 1; $i -le 4; $i++) { $map["$obj/s$i"] = @{ status = 302; location = "$obj/s$($i + 1)" } }
    $map["$obj/s5"] = @{ status = 200; file = 'site/ok.zip' }
    # 0.1.9: the release host answers 429 Retry-After 120.
    $map["$gh/v0.1.9/markers-0.1.9.zip"] = @{ status = 429; retryAfter = 120 }
    $mapFile = Join-Path $tmp 'map.json'
    $map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mapFile -Encoding utf8NoBOM
    $control = Join-Path $tmp 'control.txt'
    Set-Content -LiteralPath $control -Value $mapFile -Encoding utf8NoBOM
    $serverLog = Join-Path $tmp 'server.log'
    $server = Start-Process $pwsh -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverLog -RedirectStandardError (Join-Path $tmp 'server.err') -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', (Join-Path $tests 'https-fixture-server.ps1'), '-ControlFile', $control, '-ParentPid', $PID)
    $port = $null; $cert = $null
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while (-not ($port -and $cert)) {
        if ([datetime]::UtcNow -gt $deadline -or $server.HasExited) { throw "the fixture server did not start: $(Get-Content $serverLog -Raw -ErrorAction SilentlyContinue)" }
        Start-Sleep -Milliseconds 200
        foreach ($l in @(Get-Content -LiteralPath $serverLog -ErrorAction SilentlyContinue)) {
            if ($l -match '^port: (\d+)$') { $port = $Matches[1] }
            if ($l -match '^cert: ([0-9a-f]{64})$') { $cert = $Matches[1] }
        }
    }
    $net = @('-Proxy', "127.0.0.1:$port", '-PinCert', $cert, '-TrustedKeys', $trustFile)

    # ---------------------------------------------------------------- downloads
    $dl = Join-Path $tmp 'downloads'
    function Download([string] $version, [string] $id = 'nuclearnightmare-community.markers', [string] $folder = $dl, [string] $state) {
        $extra = if ($state) { @('-StateFile', $state) } else { @() }
        Run-Exe -Download -Index $ixFile -Revoked $rvFile -Id $id -Version $version -OutDir $folder @net @extra
    }
    function Payload { $l = $script:out | Where-Object { $_.StartsWith('payload: ') } | Select-Object -First 1; if ($l) { $l.Substring(9) | ConvertFrom-Json -AsHashtable } }
    function Left([string] $folder = $dl) { @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue | ForEach-Object Name) }
    $final = "$sha.zip"

    Download '0.1.0'
    $file = Join-Path $dl $final
    Ok ((Outcome) -eq 'outcome: ok' -and $script:code -eq 0 -and (Has-Line "file: $file") -and (Test-Path -LiteralPath $file) -and
        ((Get-FileHash -LiteralPath $file).Hash -eq $sha.ToUpperInvariant()) -and (Left).Count -eq 1) 'download ok: <sha256>.zip in the folder, its hash the index''s' (Shown)
    $pl = Payload
    Ok ($pl -and $pl.Count -eq 5 -and $pl.id -ceq 'nuclearnightmare-community.markers' -and $pl.version -ceq '0.1.0' -and $pl.sha256 -ceq $sha -and $pl.size -eq $bytes.Length -and
        $pl.file -ceq $file) 'download ok: payload {id, version, sha256, size, file}' (Shown)
    Download '0.1.0'
    Ok ((Outcome) -eq 'outcome: ok' -and (Has-Line 'already downloaded')) 'download again: the verified file is kept, nothing fetched' (Shown)
    Remove-Item -LiteralPath $file
    Download '0.1.1'
    Ok ((Outcome) -eq 'outcome: ok' -and (Test-Path -LiteralPath $file)) 'download through a redirect to objects.githubusercontent.com: ok' (Shown)
    Remove-Item -LiteralPath $file
    foreach ($c in @(@{ v = '0.1.2'; want = 'size-mismatch'; text = 'is 8191 bytes; the index says 8192'; what = 'truncated' },
                     @{ v = '0.1.3'; want = 'size-mismatch'; text = 'is more than 8192 bytes'; what = 'grown by a byte' },
                     @{ v = '0.1.4'; want = 'hash-mismatch'; text = "the index says $sha"; what = 'one byte changed' },
                     @{ v = '0.1.5'; want = 'url-not-allowed'; text = 'to https://evil.example/m.zip is not allowed'; what = 'redirect to another host' },
                     @{ v = '0.1.6'; want = 'unreachable'; text = 'more than 5 redirects'; what = '6 redirects' },
                     @{ v = '0.1.7'; want = 'unreachable'; text = 'HTTP 503'; what = 'HTTP 503' })) {
        Download $c.v
        $left = Left
        $pl = Payload
        Ok ((Outcome) -eq "outcome: $($c.want)" -and $script:code -eq 1 -and (Has-Line $c.text) -and $left.Count -eq 0 -and $pl -and $pl.Count -eq 2 -and $pl.version -ceq $c.v) "download $($c.what): $($c.want), nothing left in the folder, payload {id, version}" "$(Shown); left: $($left -join ', ')"
    }
    Download '0.1.8'
    Ok ((Outcome) -eq 'outcome: ok' -and (Test-Path -LiteralPath $file)) 'download through exactly 5 redirects: ok' (Shown)
    Remove-Item -LiteralPath $file
    # Back-off on the release host, under -StateFile (core's state.json): saved, then the next download is refused unasked.
    $boState = Join-Path $tmp 'bo\state.json'
    $url9 = "$gh/v0.1.9/markers-0.1.9.zip"
    Download '0.1.9' -state $boState
    $bo = if (Test-Path $boState) { (Get-Content $boState -Raw | ConvertFrom-Json -AsHashtable).backoff } else { $null }
    Ok ((Outcome) -eq 'outcome: unreachable' -and (Has-Line 'HTTP 429') -and (Has-Line 'github.com backed off until') -and $bo -and $bo.ContainsKey('github.com')) 'release host 429 Retry-After: unreachable, github.com backed off in the state file' (Shown)
    $seen = @(Get-Content $serverLog | Where-Object { $_.Contains($url9) }).Count
    Download '0.1.9' -state $boState
    $seen2 = @(Get-Content $serverLog | Where-Object { $_.Contains($url9) }).Count
    Ok ((Outcome) -eq 'outcome: unreachable' -and (Has-Line 'github.com is backed off until') -and $seen -eq 1 -and $seen2 -eq 1) 'a second download while backed off: refused without a request' "$(Shown); requests $seen, $seen2"
    Download '9.9.9'
    Ok ((Outcome) -eq 'outcome: refused' -and (Has-Line 'message: not in the catalog')) 'download of an unknown version: refused, not in the catalog' (Shown)
    Download '0.1.0' 'nuclearnightmare-community.other'
    Ok ((Outcome) -eq 'outcome: refused' -and (Has-Line 'message: not in the catalog')) 'download of an unknown id: refused, not in the catalog' (Shown)
    Download '0.3.0' 'GitHub.com/NuclearNightmare-Community.Markers'
    $pl = Payload
    Ok ((Outcome) -eq 'outcome: revoked' -and (Has-Line 'is revoked (disable): crash on map load') -and (Left).Count -eq 0 -and $pl -and $pl.Count -eq 2 -and
        $pl.id -ceq 'nuclearnightmare-community.markers' -and $pl.version -ceq '0.3.0') 'download of a revoked version (disable, id in another form): revoked, nothing fetched, payload {id, version}' (Shown)
    Download '0.3.1'
    Ok ((Outcome) -eq 'outcome: revoked' -and (Has-Line 'is revoked (block): bad build')) 'download of a revoked version (block): revoked' (Shown)
    Download '0.2.0'
    Ok ((Outcome) -eq 'outcome: refused' -and (Has-Line 'message: too large')) 'download of an index size over 256 MiB: refused, too large' (Shown)
    $full = Join-Path $tmp 'full'
    New-Item -ItemType Directory -Force $full | Out-Null
    $fs = [IO.File]::Create((Join-Path $full 'other.zip')); $fs.SetLength(512MB - 4096); $fs.Dispose()
    Download '0.1.0' -folder $full
    Ok ((Outcome) -eq 'outcome: refused' -and (Has-Line 'message: downloads folder full')) 'download that would pass 512 MiB in the folder: refused, downloads folder full' (Shown)
    Remove-Item -LiteralPath (Join-Path $full 'other.zip')
    # An interrupted download's leftover .part-* file doesn't count toward the cap, and the download removes it.
    $fs = [IO.File]::Create((Join-Path $full '.part-deadbeef')); $fs.SetLength(600MB); $fs.Dispose()
    Download '0.1.0' -folder $full
    Ok ((Outcome) -eq 'outcome: ok' -and -not (Test-Path -LiteralPath (Join-Path $full '.part-deadbeef'))) 'the same download once the folder has room (a 600 MiB .part-* leftover not counted): ok, leftover removed' (Shown)
    Run-Exe -Download -Index $ixFile -Id 'nucleus' -Version '0.1.0' -OutDir $dl @net
    Ok ((Outcome) -eq 'outcome: error' -and (Has-Line 'an id needs a namespace')) 'download with an id the normalizer refuses: error' (Shown)

    # ---------------------------------------------------------------- bounds
    $deep = Join-Path $tmp 'deep'
    New-Item -ItemType Directory -Force $deep | Out-Null
    $deepIx = Join-Path $deep 'index.json'
    $nest = ('[' * 64) + (']' * 64)
    Set-Content -LiteralPath $deepIx -Value "{`"schema`":1,`"serial`":1,`"issued`":`"2026-11-20T10:00:00Z`",`"packages`":[],`"x`":$nest}" -Encoding utf8NoBOM -NoNewline
    Sign $deepIx 'release'
    Run-Exe -Index $deepIx -TrustedKeys $trustFile
    Ok ((Outcome) -eq 'outcome: invalid-index' -and (Has-Line 'index is not valid JSON')) 'an index nested 65 deep is invalid-index (not valid JSON)' (Shown)
    $ok64 = Join-Path $deep 'index64.json'
    $nest = ('[' * 63) + (']' * 63)
    Set-Content -LiteralPath $ok64 -Value "{`"schema`":1,`"serial`":1,`"issued`":`"2026-11-20T10:00:00Z`",`"packages`":[],`"x`":$nest}" -Encoding utf8NoBOM -NoNewline
    Sign $ok64 'release'
    Run-Exe -Index $ok64 -TrustedKeys $trustFile
    Ok ((Outcome) -eq 'outcome: ok') 'an index nested 64 deep is read' (Shown)

    # The fixture server's certificate without -PinCert: Windows' own checks refuse it, so no base is reachable.
    $site2 = Join-Path $tmp 'unpinned'
    New-Item -ItemType Directory -Force $site2 | Out-Null
    Copy-Item $ixFile, "$ixFile.minisig" $site2
    $pmap = @{ 'https://nuclearnightmare-community.github.io/catalog/keys.json' = @{ status = 404 }
               'https://nuclearnightmare-community.github.io/catalog/index.json' = @{ status = 200; file = 'unpinned/index.json' }
               'https://nuclearnightmare-community.github.io/catalog/index.json.minisig' = @{ status = 200; file = 'unpinned/index.json.minisig' }
               'https://nuclearnightmare-community.github.io/catalog/revoked.json' = @{ status = 404 } }
    $pmapFile = Join-Path $tmp 'pinned-map.json'
    $pmap | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $pmapFile -Encoding utf8NoBOM
    Set-Content -LiteralPath $control -Value $pmapFile -Encoding utf8NoBOM
    Run-Exe -Fetch -OutDir (Join-Path $tmp 'fetch-pinned') -Proxy "127.0.0.1:$port" -PinCert $cert -TrustedKeys $trustFile
    Ok ((Outcome) -eq 'outcome: ok' -and (Has-Line 'endpoint: https://nuclearnightmare-community.github.io/catalog/ ok')) 'the same fetch with the pinned certificate: ok (control)' (Shown)
    Run-Exe -Fetch -OutDir (Join-Path $tmp 'fetch-unpinned') -Proxy "127.0.0.1:$port" -TrustedKeys $trustFile
    Ok ((Outcome) -eq 'outcome: error' -and (Has-Line 'no endpoint reachable and no verified copy') -and
        (Has-Line 'endpoint: https://nuclearnightmare-community.github.io/catalog/ unreachable: network error')) 'an unpinned self-signed certificate is refused by Windows'' checks: unreachable' (Shown)
} catch {
    $script:failed++
    Write-Host "FAIL: runner failure: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "catalog.tests: $($script:passed) passed, $($script:failed) failed"
if ($script:failed) { exit 1 }
exit 0
