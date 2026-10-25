# 真实渲染验证：启动桌宠 → 截折叠态特写 → 点一下展开 → 再截特写 → 报窗口矩形。
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify\shoot.ps1
# 注意：写在文件里的中文必须带 UTF-8 BOM，否则 5.1 按 GBK 解码会乱码（见 README 排错）。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Shot {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  // 按标题子串找可见窗口：FindWindow 对含 · 的标题不可靠。
  public static IntPtr Find(string part) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(300);
      GetWindowTextW(h, sb, 300);
      if (sb.ToString().Contains(part)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@

# DPI 感知必须在任何取坐标/截图之前：否则 GetWindowRect 给虚拟化坐标而 CopyFromScreen 按物理像素取，截错地方。
[void][Shot]::SetProcessDPIAware()

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$shots = Join-Path $here 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
Get-ChildItem $shots -Filter *.png | Remove-Item -Force -ErrorAction SilentlyContinue

# 清掉上一次跑着的窗口（排除自身：本进程命令行也含 pet-chat 路径）
$self = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
  Where-Object { $_.ProcessId -ne $self -and $_.CommandLine -like '*pet-chat.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

Start-Process -FilePath 'powershell.exe' -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
  '-File', (Join-Path $root 'pet-chat.ps1')
) | Out-Null
Start-Sleep -Seconds 6

# 先把窗口挪到左上角：右下角那片常被别的置顶桌宠（dsh-tauri-pet）盖住，点击会落到它身上。
$h0 = [Shot]::Find('鲸鱼')
if ($h0 -ne [IntPtr]::Zero) {
  [void][Shot]::SetWindowPos($h0, [IntPtr]::Zero, 80, 80, 0, 0, 0x0001 -bor 0x0004)
  Start-Sleep -Milliseconds 500
}

function Shot([string]$name, $rect, [bool]$zoom) {
  $bmp = New-Object Drawing.Bitmap($rect.Width, $rect.Height)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.X, $rect.Y, 0, 0, $bmp.Size)
  $g.Dispose()
  $path = Join-Path $shots $name
  $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  if ($zoom) {
    $big = New-Object Drawing.Bitmap($bmp, ($rect.Width * 2), ($rect.Height * 2))
    $big.Save((Join-Path $shots ($name -replace '\.png$', '-2x.png')), [Drawing.Imaging.ImageFormat]::Png)
    $big.Dispose()
  }
  $bmp.Dispose()
  return $path
}

function WindowRect {
  $h = [Shot]::Find('鲸鱼')
  if ($h -eq [IntPtr]::Zero) { return $null }
  $r = New-Object Shot+RECT
  [void][Shot]::GetWindowRect($h, [ref]$r)
  return [pscustomobject]@{ H = $h; Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom; Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
}

$w1 = WindowRect
if ($null -eq $w1) { Write-Output '{"error":"窗口未找到"}'; exit 1 }

$pad = 12
$crop1 = New-Object Drawing.Rectangle(($w1.Left - $pad), ($w1.Top - $pad), ($w1.Width + $pad * 2), ($w1.Height + $pad * 2))
Shot 'crop-collapsed.png' $crop1 $true | Out-Null

# 点一下窗口中心 → 应展开成聊天卡
[void][Shot]::SetCursorPos([int](($w1.Left + $w1.Right) / 2), [int](($w1.Top + $w1.Bottom) / 2))
Start-Sleep -Milliseconds 250
[Shot]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 90
[Shot]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Seconds 2

$w2 = WindowRect
if ($null -ne $w2) {
  $crop2 = New-Object Drawing.Rectangle(($w2.Left - $pad), ($w2.Top - $pad), ($w2.Width + $pad * 2), ($w2.Height + $pad * 2))
  Shot 'crop-expanded.png' $crop2 $false | Out-Null
}

[pscustomobject]@{
  dpiAware  = $true
  collapsed = if ($w1) { "$($w1.Width)x$($w1.Height) at $($w1.Left),$($w1.Top)" } else { 'none' }
  expanded  = if ($w2) { "$($w2.Width)x$($w2.Height) at $($w2.Left),$($w2.Top)" } else { 'none' }
  shots     = (Get-ChildItem $shots -Filter *.png | Select-Object -ExpandProperty Name) -join ', '
} | ConvertTo-Json
