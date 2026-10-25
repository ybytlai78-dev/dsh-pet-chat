# 验证「新建会话」按钮：点一下 → 标题变「新会话」、消息区清空、工作区保持。
# 产物：verify/shots/card-v3-newsession.png
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('UiCap' -as [type])) {
  Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class UiCap {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static IntPtr Find(string needle) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(512);
      GetWindowTextW(h, sb, sb.Capacity);
      if (sb.ToString().IndexOf(needle, StringComparison.Ordinal) >= 0) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static void Click(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(120);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(60);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
  }
}
'@
}
[void][UiCap]::SetProcessDPIAware()

$shots = Join-Path $PSScriptRoot 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
$root = Split-Path $PSScriptRoot
$card = Join-Path $root 'pet-chat.ps1'

# 只杀真正的卡片进程（命令行必须精确以 pet-chat.ps1 结尾，别误伤外层 pwsh）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\s+"?[^"]*pet-chat\.ps1"?\s*(-|$)' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
Start-Sleep -Milliseconds 500

Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:USERPROFILE '.dsh\pet-chat\card.json')
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $card, '-Show' -WindowStyle Hidden
Start-Sleep -Seconds 6

$h = [UiCap]::Find('看屏幕')
if ($h -eq [IntPtr]::Zero) { Write-Output 'card NOT-FOUND'; exit 2 }
[void][UiCap]::SetWindowPos($h, [IntPtr]::Zero, 240, 60, 0, 0, 0x0001 -bor 0x0004)
Start-Sleep -Milliseconds 800

$r = New-Object UiCap+RECT
[void][UiCap]::GetWindowRect($h, [ref]$r)
$g0 = [Drawing.Graphics]::FromHwnd($h)
$k = $g0.DpiX / 96.0                          # 布局用的缩放（不是靠窗口宽度反推）
$g0.Dispose()

function Save($path) {
  $rr = New-Object UiCap+RECT
  [void][UiCap]::GetWindowRect($h, [ref]$rr)
  $bmp = New-Object Drawing.Bitmap(($rr.Right - $rr.Left), ($rr.Bottom - $rr.Top))
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rr.Left, $rr.Top, 0, 0, $bmp.Size)
  $g.Dispose()
  $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output ("$([IO.Path]::GetFileName($path))  rect=$($rr.Left),$($rr.Top) $($rr.Right-$rr.Left)x$($rr.Bottom-$rr.Top)")
}

Save (Join-Path $shots 'card-v3-before-new.png')

# 「新建会话」在 header(44) + wsBar(34) 那一条的最右边：宽 86、右内缩 14
$btnX = [int]($r.Right - (14 + 43) * $k)
$btnY = [int]($r.Top + (44 + 17) * $k)
Write-Output "click new-session at $btnX,$btnY (k=$k)"
[UiCap]::Click($btnX, $btnY)
Start-Sleep -Milliseconds 2500

Save (Join-Path $shots 'card-v3-newsession.png')
Write-Output 'new-session probe done'
