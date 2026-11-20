<#
.SYNOPSIS
  Draws core's eleven placeholder icons: white on transparent, 128x128 PNGs, next to this script.
.DESCRIPTION
  gear, checkbox-on, checkbox-off, lock, warning, restart, and the five scope icons (Mod Manager story 12, core 0.21.0):
  scope-host (a house), scope-client (a person), scope-host-plus (a house with a small person), scope-both (a house and a
  person with a plus) and scope-unknown (a question mark in a ring). They are placeholders (our own work, plain shapes drawn
  with System.Drawing) until the user's art replaces them: see README.md here. build.ps1 hands this folder to CoreGen,
  which imports each PNG as /Game/Mods/<Core>/Icons/T_<Key in CamelCase> (UserInterface2D, no mips, UI group, never
  streamed); core tints them at runtime, so they stay white. Re-running it rewrites the eleven files.
.EXAMPLE
  pwsh -File art/icons/draw.ps1
#>
param([string] $Out = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$N = 128
$white = [System.Drawing.Color]::White

function New-Canvas {
    $bmp = [System.Drawing.Bitmap]::new($N, $N, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    return $bmp, $g
}
function New-Pen([float] $w) {
    $p = [System.Drawing.Pen]::new($white, $w)
    $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    return $p
}
function RoundRect([float] $x, [float] $y, [float] $w, [float] $h, [float] $r) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}
function Save($bmp, $g, [string] $name) {
    $g.Dispose()
    $file = Join-Path $Out "$name.png"
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "wrote $file"
}
$brush = [System.Drawing.SolidBrush]::new($white)

# checkbox-off: a rounded square frame.
$bmp, $g = New-Canvas
$g.DrawPath((New-Pen 10), (RoundRect 14 14 100 100 16))
Save $bmp $g 'checkbox-off'

# checkbox-on: the same frame with a tick.
$bmp, $g = New-Canvas
$g.DrawPath((New-Pen 10), (RoundRect 14 14 100 100 16))
$g.DrawLines((New-Pen 13), [System.Drawing.PointF[]]@([System.Drawing.PointF]::new(36, 66), [System.Drawing.PointF]::new(56, 86), [System.Drawing.PointF]::new(93, 43)))
Save $bmp $g 'checkbox-on'

# gear: a ring of eight teeth around a disc with a hole (the polygon filled with the winding rule; the hole cut out with SourceCopy).
$bmp, $g = New-Canvas
$path = [System.Drawing.Drawing2D.GraphicsPath]::new([System.Drawing.Drawing2D.FillMode]::Winding)
$cx, $cy = 64.0, 64.0
$teeth = 8
$rOut, $rIn = 58.0, 44.0
$pts = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
for ($i = 0; $i -lt $teeth; $i++) {
    $a0 = 2 * [math]::PI * $i / $teeth
    $half = [math]::PI / $teeth
    foreach ($s in @(@(-0.62, $rIn), @(-0.40, $rOut), @(0.40, $rOut), @(0.62, $rIn), @(1.38, $rIn))) {
        $a = $a0 + $s[0] * $half
        $pts.Add([System.Drawing.PointF]::new([float]($cx + $s[1] * [math]::Cos($a)), [float]($cy + $s[1] * [math]::Sin($a))))
    }
}
$path.AddPolygon($pts.ToArray())
$g.FillPath($brush, $path)
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$hole = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Transparent)
$g.FillEllipse($hole, 44, 44, 40, 40)
Save $bmp $g 'gear'

# lock: a shackle over a rounded body with a keyhole.
$bmp, $g = New-Canvas
$g.DrawArc((New-Pen 11), 38, 14, 52, 56, 180, 180)
$g.DrawLine((New-Pen 11), 38, 42, 38, 60)
$g.DrawLine((New-Pen 11), 90, 42, 90, 60)
$g.FillPath($brush, (RoundRect 24 58 80 58 10))
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$hole = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Transparent)
$g.FillEllipse($hole, 56, 72, 16, 16)
$g.FillRectangle($hole, 60, 84, 8, 18)
Save $bmp $g 'lock'

# warning: a triangle frame with an exclamation mark.
$bmp, $g = New-Canvas
$tri = [System.Drawing.PointF[]]@([System.Drawing.PointF]::new(64, 12), [System.Drawing.PointF]::new(118, 112), [System.Drawing.PointF]::new(10, 112))
$g.DrawPolygon((New-Pen 10), $tri)
$g.DrawLine((New-Pen 11), 64, 44, 64, 78)
$g.FillEllipse($brush, 57.5, 88, 13, 13)
Save $bmp $g 'warning'

# restart: a circular arrow (an open ring and an arrowhead at its end).
$bmp, $g = New-Canvas
$g.DrawArc((New-Pen 11), 22, 22, 84, 84, -60, 300)
# The ring ends at -60 degrees (upper right); the head points along the turn there.
$a = -60 * [math]::PI / 180
$ex, $ey = (64 + 42 * [math]::Cos($a)), (64 + 42 * [math]::Sin($a))
$head = [System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new([float]($ex + 24), [float]($ey - 6)),
    [System.Drawing.PointF]::new([float]($ex - 10), [float]($ey - 22)),
    [System.Drawing.PointF]::new([float]($ex - 4), [float]($ey + 18)))
$g.FillPolygon($brush, $head)
Save $bmp $g 'restart'

# --- Scope icons (Mod Manager story 12, core 0.21.0): set A, pictograms. House = the host, person = a player.
$clear = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Transparent)
function P([float] $x, [float] $y) { [System.Drawing.PointF]::new($x, $y) }
# A house in a box s wide and s tall at (x, y): a filled roof and a body with a door cut out.
function House($g, [float] $x, [float] $y, [float] $s) {
    $roof = [System.Drawing.PointF[]]@((P ($x + $s / 2) $y), (P ($x + $s) ($y + 0.48 * $s)), (P $x ($y + 0.48 * $s)))
    $g.FillPolygon($brush, $roof)
    $g.FillRectangle($brush, $x + 0.14 * $s, $y + 0.44 * $s, 0.72 * $s, 0.56 * $s)
    $old = $g.CompositingMode
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $g.FillRectangle($clear, $x + 0.40 * $s, $y + 0.66 * $s, 0.20 * $s, 0.34 * $s)
    $g.CompositingMode = $old
}
# A person (head and shoulders) in a box s wide at (x, y).
function Person($g, [float] $x, [float] $y, [float] $s) {
    $g.FillEllipse($brush, $x + 0.30 * $s, $y, 0.40 * $s, 0.40 * $s)
    $body = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $body.AddArc($x + 0.06 * $s, $y + 0.48 * $s, 0.88 * $s, 0.80 * $s, 180, 180)
    $body.AddLine($x + 0.94 * $s, $y + 0.88 * $s, $x + 0.06 * $s, $y + 0.88 * $s)
    $body.CloseFigure()
    $g.FillPath($brush, $body)
}

# scope-host: only the host needs it.
$bmp, $g = New-Canvas; House $g 12 10 104; Save $bmp $g 'scope-host'
# scope-client: works on its own, whether you host or join.
$bmp, $g = New-Canvas; Person $g 16 12 96; Save $bmp $g 'scope-client'
# scope-host-plus: the host needs it, players who have it get more. A big house with a small person at the lower right
# (smaller than in scope-both and without the plus, so the two stay apart at 28 px).
$bmp, $g = New-Canvas; House $g 4 6 90; Person $g 82 80 44; Save $bmp $g 'scope-host-plus'
# scope-both: the host and every player need it. A house and a person with a plus.
$bmp, $g = New-Canvas
House $g 2 8 56; Person $g 70 66 56
$g.DrawLine((New-Pen 9), 98, 12, 98, 50); $g.DrawLine((New-Pen 9), 79, 31, 117, 31)
Save $bmp $g 'scope-both'
# scope-unknown: the mod doesn't say. A question mark in a ring.
$bmp, $g = New-Canvas
$g.DrawEllipse((New-Pen 9), 10, 10, 108, 108)
$q = [System.Drawing.Drawing2D.GraphicsPath]::new()
$q.AddArc(44, 30, 40, 36, 200, 250)
$g.DrawPath((New-Pen 11), $q)
$g.DrawLine((New-Pen 11), 64, 66, 64, 76)
$g.FillEllipse($brush, 57, 86, 14, 14)
Save $bmp $g 'scope-unknown'
