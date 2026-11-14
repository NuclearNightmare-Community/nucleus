<#
.SYNOPSIS
  Draws core's six placeholder icons: white on transparent, 128x128 PNGs, next to this script.
.DESCRIPTION
  gear, checkbox-on, checkbox-off, lock, warning, restart. They are placeholders (our own work, plain shapes drawn
  with System.Drawing) until the user's art replaces them: see README.md here. build.ps1 hands this folder to CoreGen,
  which imports each PNG as /Game/Mods/<Core>/Icons/T_<Key in CamelCase> (UserInterface2D, no mips, UI group, never
  streamed); core tints them at runtime, so they stay white. Re-running it rewrites the six files.
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
