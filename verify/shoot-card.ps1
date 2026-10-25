#requires -Version 5.1
# 验证新版聊天卡：停靠位置 / 尺寸记忆 / 拖边缩放
#   1) 重启卡片进程，删掉 card.json（回到默认停靠位置）
#   2) 把官方桌宠挪到 (160,160)，点它唤出卡片
#   3) 截图：默认停靠态
#   4) 拖右边缘 +180px（走系统 WM_NCHITTEST 缩放），断言宽度变大
#   5) 再截一张：放大后布局是否跟着走
#   6) 复原桌宠位置
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# 必须 DPI 感知：否则 GetWindowRect 给虚拟化坐标、CopyFromScreen 按物理像素取，裁图会整体偏移。
Add-Type @'
using System.Runtime.InteropServices;
public static class CDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[void][CDpi]::SetProcessDPIAware()

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class CardWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  public static IntPtr FindPet() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var cn = new StringBuilder(200); GetClassNameW(h, cn, 200);
      if (cn.ToString() != "Tauri Window") return true;
      var tt = new StringBuilder(300); GetWindowTextW(h, tt, 300);
      if (tt.ToString().IndexOf("Pet", StringComparison.OrdinalIgnoreCase) < 0) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      try { if (System.Diagnostics.Process.GetProcessById((int)pid).ProcessName != "deepseek-harness-desktop") return true; }
      catch { return true; }
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }

  public static IntPtr FindCard() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      var tt = new StringBuilder(300); GetWindowTextW(h, tt, 300);
      if (tt.ToString().IndexOf("看屏幕") < 0) return true;
      if (!IsWindowVisible(h)) return true;
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }
}
'@

$root = Split-Path -Parent $PSScriptRoot
$shots = Join-Path $PSScriptRoot 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
$cardScript = Join-Path $root 'pet-chat.ps1'
$geom = Join-Path $env:USERPROFILE '.dsh\pet-chat\card.json'

function Save-Shot { param([string]$Path)
  $b = [Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height)
  $g = [Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size) } finally { $g.Dispose() }
  $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

function Crop-Shot { param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Path, [int]$Pad = 10)
  $bmp = New-Object Drawing.Bitmap(($W + $Pad * 2), ($H + $Pad * 2))
  $g = [Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen(($X - $Pad), ($Y - $Pad), 0, 0, $bmp.Size) } finally { $g.Dispose() }
  $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

function Click-At { param([int]$X, [int]$Y)
  [void][CardWin]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 130
  [CardWin]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 90
  [CardWin]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 800
}

# 1) 重启（排除自己），清掉几何记忆
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*pet-chat.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400
Remove-Item -LiteralPath $geom -Force -ErrorAction SilentlyContinue
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$cardScript`""
Start-Sleep -Seconds 3

# 2) 挪桌宠 → 点它
$pet = [CardWin]::FindPet()
if ($pet -eq [IntPtr]::Zero) { throw '找不到官方桌宠窗口' }
$orig = New-Object CardWin+RECT
[void][CardWin]::GetWindowRect($pet, [ref]$orig)
[void][CardWin]::SetWindowPos($pet, [IntPtr]::Zero, 160, 160, 0, 0, 0x0001 -bor 0x0004)
Start-Sleep -Milliseconds 400
$moved = New-Object CardWin+RECT
[void][CardWin]::GetWindowRect($pet, [ref]$moved)
$cx = [int](($moved.Left + $moved.Right) / 2)
$cy = [int]($moved.Top + ($moved.Bottom - $moved.Top) * 0.70)
Click-At $cx $cy
"pet = $($moved.Left),$($moved.Top),$($moved.Right),$($moved.Bottom)   clicked=$cx,$cy"

$card = [CardWin]::FindCard()
if ($card -eq [IntPtr]::Zero) { throw '点了桌宠但卡片没出现' }
$r0 = New-Object CardWin+RECT
[void][CardWin]::GetWindowRect($card, [ref]$r0)
"card-default = $($r0.Left),$($r0.Top) size=$($r0.Right - $r0.Left)x$($r0.Bottom - $r0.Top)"
Crop-Shot $r0.Left $r0.Top ($r0.Right - $r0.Left) ($r0.Bottom - $r0.Top) (Join-Path $shots 'card-default.png') 0

# 3) 拖右边缘 +180px
$edgeX = $r0.Right - 3
$midY = [int](($r0.Top + $r0.Bottom) / 2)
[void][CardWin]::SetCursorPos($edgeX, $midY)
Start-Sleep -Milliseconds 150
[CardWin]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 200
for ($i = 1; $i -le 8; $i++) {
  [void][CardWin]::SetCursorPos(($edgeX + $i * 40), $midY)
  Start-Sleep -Milliseconds 120
}
Start-Sleep -Milliseconds 200
[CardWin]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 700

$r1 = New-Object CardWin+RECT
[void][CardWin]::GetWindowRect($card, [ref]$r1)
$w0 = $r0.Right - $r0.Left
$w1 = $r1.Right - $r1.Left
"card-resized = $($r1.Left),$($r1.Top) size=${w1}x$($r1.Bottom - $r1.Top)   widthDelta=$($w1 - $w0)  resize-ok=$($w1 -gt $w0 + 100)"
Crop-Shot $r1.Left $r1.Top $w1 ($r1.Bottom - $r1.Top) (Join-Path $shots 'card-resized.png') 0

# 4) 收起重开，验证尺寸被记住
Click-At $cx $cy
Start-Sleep -Milliseconds 400
Click-At $cx $cy
$r2 = New-Object CardWin+RECT
[void][CardWin]::GetWindowRect($card, [ref]$r2)
"card-reopen = size=$($r2.Right - $r2.Left)x$($r2.Bottom - $r2.Top)  persisted=$((($r2.Right - $r2.Left) -eq $w1))"

# 5) 复原桌宠
[void][CardWin]::SetWindowPos($pet, [IntPtr]::Zero, $orig.Left, $orig.Top, 0, 0, 0x0001 -bor 0x0004)
'done'
