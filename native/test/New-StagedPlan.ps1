<#
.SYNOPSIS
  Stages a change the way Mod Manager v2 stories 5-7 will (a test tool; Mod Manager v2 story 3): staged files named by
  their SHA-256 and a plan, in a <Core>Data folder (native/src/stage/plan.hpp has the format).
.DESCRIPTION
  -Ops is a list of hashtables, in order:
    @{ Op = 'put';     Owner = 'ModA'; Target = '<relative target>'; Source = '<file>' }   (or Bytes = [byte[]], or Text = '<string, UTF-8>')
    @{ Op = 'delete';  Owner = 'ModA'; Target = '<relative target>'; Sha256 = '<hex>' | '-' }
    @{ Op = 'modstxt'; Name = 'ModA'; Value = 'on' | 'remove' }
  Each put's bytes go to <Data>\staged\files\<sha256>; the plan is written as staged\plan.txt.tmp (UTF-8 without BOM,
  "\n") and renamed to staged\plan.txt, replacing a staged plan. -Raw writes the given plan text as it is (for bad-plan
  tests) and stages nothing else. Targets and names are written as given: the helper is what checks them.
  Returns the plan's txn (32 lowercase hex; random unless -Txn is given).
.EXAMPLE
  $txn = & ./native/test/New-StagedPlan.ps1 -Data C:\g\NuclearNightmare\Binaries\Win64\ue4ss\NucleusData -Ops @(
      @{ Op = 'put'; Owner = 'ModA'; Target = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\Scripts\main.lua'; Text = 'print("a")' },
      @{ Op = 'modstxt'; Name = 'ModA'; Value = 'on' })
#>
param(
    [Parameter(Mandatory)] [string] $Data,
    [object[]] $Ops = @(),
    [string] $Txn,
    [string] $Raw
)
$ErrorActionPreference = 'Stop'
if (-not $Txn) { $Txn = -join ((1..16) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) }) }
if ($Txn -cnotmatch '^[0-9a-f]{32}$') { throw "-Txn must be 32 lowercase hex digits: $Txn" }
$staged = Join-Path $Data 'staged'
$files = Join-Path $staged 'files'
New-Item -ItemType Directory -Force $files | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)

$text = if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("nucleus-plan`t1")
    $lines.Add("txn`t$Txn")
    foreach ($op in $Ops) {
        switch ($op.Op) {
            'put' {
                $bytes = if ($op.ContainsKey('Bytes')) { [byte[]]$op.Bytes } elseif ($op.ContainsKey('Text')) { $utf8.GetBytes([string]$op.Text) } else { [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $op.Source).Path) }
                $sha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').ToLowerInvariant()
                [IO.File]::WriteAllBytes((Join-Path $files $sha), $bytes)
                $lines.Add("put`t$($op.Owner)`t$sha`t$($bytes.Length)`t$($op.Target)")
            }
            'delete' { $lines.Add("delete`t$($op.Owner)`t$(if ($op.Sha256) { $op.Sha256 } else { '-' })`t$($op.Target)") }
            'modstxt' { $lines.Add("modstxt`t$($op.Name)`t$($op.Value)") }
            default { throw "unknown op: $($op.Op)" }
        }
    }
    ($lines -join "`n") + "`n"
}
$tmp = Join-Path $staged 'plan.txt.tmp'
[IO.File]::WriteAllText($tmp, $text, $utf8)
Move-Item -LiteralPath $tmp -Destination (Join-Path $staged 'plan.txt') -Force
$Txn
