#requires -Version 5.1
# 验证「点官方桌宠 → 弹聊天卡」：
#   1) 杀掉旧卡进程并重启（新版平时隐藏）
#   2) 记录官方桌宠窗原位 → 挪到 (160,160) 便于确定性点击
#   3) 全屏拍 #1：应当只有鲸鱼娘，没有聊天卡
#   4) 点鲸鱼娘中心 → 全屏拍 #2，并裁出卡片区域
#   5) 恢复桌宠原位
# 用法：powershell -NoProfile -File verify\shoot-summon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# 必须 DPI 感知：否则 GetWindowRect 给虚拟化坐标、CopyFromScreen 按物理像素取，裁出来的图会整体偏移。
Add-Type @'
using System.Runtime.InteropServices;
public static class ShotDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[void][ShotDpi]::SetProcessDPIAware()

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Pair {
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
      if (!IsWindowVisible(h)) { found = IntPtr.Zero; return true; }
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }
}
'@

$root = Split-Path -Parent $PSScriptRoot
$shots = Join-Path $PSScriptRoot 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
$script = Join-Path $root 'pet-chat.ps1'

function Save-Shot {
  param([string]$Path)
  $b = [Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height)
  $g = [Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size) } finally { $g.Dispose() }
  $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# 1) 重启卡片进程（排除自己）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*pet-chat.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`""
Start-Sleep -Seconds 3

$pet = [Pair]::FindPet()
if ($pet -eq [IntPtr]::Zero) { throw '找不到官方桌宠窗口（class=Tauri Window / title~Pet）' }
$orig = New-Object Pair+RECT
[void][Pair]::GetWindowRect($pet, [ref]$orig)
"pet-orig = $($orig.Left),$($orig.Top),$($orig.Right),$($orig.Bottom)"

# 2) 挪到固定位置（0x0004 = SWP_NOZORDER）
[void][Pair]::SetWindowPos($pet, [IntPtr]::Zero, 160, 160, 0, 0, 0x0001 -bor 0x0004)
Start-Sleep -Milliseconds 400
$moved = New-Object Pair+RECT
[void][Pair]::GetWindowRect($pet, [ref]$moved)
"pet-moved = $($moved.Left),$($moved.Top),$($moved.Right),$($moved.Bottom)"

# 3) 未点击：应当只有鲸鱼娘
Save-Shot (Join-Path $shots 'summon-1-idle.png')

# 4) 点宠物中心（热点在中段偏下，取垂直 70% 处更稳）
$cx = [int](($moved.Left + $moved.Right) / 2)
$cy = [int]($moved.Top + ($moved.Bottom - $moved.Top) * 0.70)
[void][Pair]::SetCursorPos($cx, $cy)
Start-Sleep -Milliseconds 120
[Pair]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 90
[Pair]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 900
"clicked = $cx,$cy"

$card = [Pair]::FindCard()
if ($card -eq [IntPtr]::Zero) {
  "card = NOT-SHOWN"
} else {
  $cr = New-Object Pair+RECT
  [void][Pair]::GetWindowRect($card, [ref]$cr)
  "card = $($cr.Left),$($cr.Top),$($cr.Right),$($cr.Bottom)  size=$($cr.Right - $cr.Left)x$($cr.Bottom - $cr.Top)"
  Save-Shot (Join-Path $shots 'summon-2-card.png')
  # 裁出卡片 + 12px 边距
  $pad = 12
  $w = ($cr.Right - $cr.Left) + $pad * 2
  $h = ($cr.Bottom - $cr.Top) + $pad * 2
  $full = [Drawing.Image]::FromFile((Join-Path $shots 'summon-2-card.png'))
  try {
    $crop = New-Object Drawing.Bitmap($w, $h)
    $g2 = [Drawing.Graphics]::FromImage($crop)
    try { $g2.CopyFromScreen(($cr.Left - $pad), ($cr.Top - $pad), 0, 0, $crop.Size) } finally { $g2.Dispose() }
    $crop.Save((Join-Path $shots 'summon-card-crop.png'), [Drawing.Imaging.ImageFormat]::Png)
    $crop.Dispose()
  } finally { $full.Dispose() }
}

# 4b) 再点一次应当收起（toggle）
[void][Pair]::SetCursorPos($cx, $cy)
Start-Sleep -Milliseconds 120
[Pair]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 90
[Pair]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 600
$again = [Pair]::FindCard()
if ($again -eq [IntPtr]::Zero) { 'toggle = HIDDEN (ok)' } else { 'toggle = STILL-SHOWN' }

# 5) 恢复桌宠原位
[void][Pair]::SetWindowPos($pet, [IntPtr]::Zero, $orig.Left, $orig.Top, 0, 0, 0x0001 -bor 0x0004)
'done'
