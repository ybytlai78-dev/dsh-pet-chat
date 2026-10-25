# 从整页截图里裁出卡片本体（原尺寸，便于审字）。
# 用法: powershell -File crop-cards.ps1 <page.png> <outPrefix>
param([string]$Page, [string]$Prefix)

Add-Type -AssemblyName System.Drawing

$bmp = [Drawing.Bitmap]::FromFile($Page)
$w = $bmp.Width; $h = $bmp.Height
$step = 4

function Is-White($c) { return ($c.R -gt 246 -and $c.G -gt 246 -and $c.B -gt 246) }

# 列白点计数
$col = New-Object int[] $w
for ($x = 0; $x -lt $w; $x += $step) {
  $n = 0
  for ($y = 0; $y -lt $h; $y += $step) { if (Is-White $bmp.GetPixel($x, $y)) { $n++ } }
  for ($k = 0; $k -lt $step -and ($x + $k) -lt $w; $k++) { $col[$x + $k] = $n }
}

# 找出列计数 > 总数的 25% 的连续段 = 卡片所在列带
$thr = [int](($h / $step) * 0.25)
$runs = @()
$start = -1
for ($x = 0; $x -lt $w; $x++) {
  $hot = $col[$x] -ge $thr
  if ($hot -and $start -lt 0) { $start = $x }
  elseif (-not $hot -and $start -ge 0) { if (($x - $start) -ge 100) { $runs += , @($start, $x - 1) }; $start = -1 }
}
if ($start -ge 0 -and ($w - $start) -ge 100) { $runs += , @($start, $w - 1) }

$i = 0
foreach ($r in $runs) {
  $x0 = [Math]::Max($r[0] - 2, 0); $x1 = [Math]::Min($r[1] + 2, $w - 1)
  # 在该列带内找行范围
  $y0 = -1; $y1 = -1
  $rowMin = [int](($x1 - $x0) * 0.5)
  for ($y = 0; $y -lt $h; $y++) {
    $n = 0
    for ($x = $x0; $x -le $x1; $x += $step) { if (Is-White $bmp.GetPixel($x, $y)) { $n++ } }
    if ($n -ge ($rowMin / $step)) {
      if ($y0 -lt 0) { $y0 = $y }
      $y1 = $y
    }
  }
  if ($y0 -ge 0 -and ($y1 - $y0) -ge 60) {
    $cw = $x1 - $x0 + 1; $ch = $y1 - $y0 + 1
    $out = New-Object Drawing.Bitmap $cw, $ch
    $g = [Drawing.Graphics]::FromImage($out)
    $g.DrawImage($bmp, (New-Object Drawing.Rectangle 0, 0, $cw, $ch), (New-Object Drawing.Rectangle $x0, $y0, $cw, $ch), [Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $path = "$Prefix-$i.png"
    $out.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $out.Dispose()
    "run$i : x=$x0..$x1 y=$y0..$y1  size=${cw}x${ch} -> $path"
    $i++
  }
}
$bmp.Dispose()
