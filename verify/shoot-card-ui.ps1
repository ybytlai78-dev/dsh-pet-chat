# 卡片 UI 视觉验证：唤出卡片 → 截图 → 改尺寸截图（验证 Layout 重排）→ 复原。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File verify\shoot-card-ui.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;
public class UiCap {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static IntPtr Find(string kw) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h,l) => { var t = new StringBuilder(300); GetWindowTextW(h,t,300);
      if (t.ToString().IndexOf(kw) < 0) return true;
      if (!IsWindowVisible(h)) return true; found = h; return false; }, IntPtr.Zero);
    return found;
  }
  public static IntPtr FindPet() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h,l) => {
      var t = new StringBuilder(300); GetWindowTextW(h,t,300);
      var c = new StringBuilder(300); GetClassNameW(h,c,300);
      if (c.ToString() != "Tauri Window") return true;
      if (t.ToString().IndexOf("Pet") < 0) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r; GetWindowRect(h, out r);
      if (r.Right - r.Left < 200) return true;
      found = h; return false; }, IntPtr.Zero);
    return found;
  }
}
'@
[void][UiCap]::SetProcessDPIAware()
$shots = Join-Path $PSScriptRoot 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

function Save-Window([IntPtr]$h, [string]$name) {
  $r = New-Object UiCap+RECT; [void][UiCap]::GetWindowRect($h, [ref]$r)
  $w = $r.Right - $r.Left; $h2 = $r.Bottom - $r.Top
  if ($w -le 0 -or $h2 -le 0) { throw "empty rect for $name" }
  $bmp = New-Object Drawing.Bitmap $w, $h2
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
  $bmp.Save((Join-Path $shots $name), [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "$name  rect=$($r.Left),$($r.Top) ${w}x${h2}"
}

# 1) 干净重启卡片进程（PS 5.1 的 Get-Process 没有 CommandLine 属性，必须走 CIM）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'pet-chat\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 700
Remove-Item (Join-Path $env:USERPROFILE '.dsh\pet-chat\card.json') -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 200
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
  (Join-Path (Split-Path $PSScriptRoot) 'pet-chat.ps1'), '-Show', '-Demo' -WindowStyle Hidden
Start-Sleep -Seconds 3

# 2) 桌宠挪到左上角，点击唤出卡片
$pet = [UiCap]::FindPet()
if ($pet -eq [IntPtr]::Zero) { throw 'pet window not found' }
[void][UiCap]::SetWindowPos($pet, [IntPtr]::Zero, 160, 160, 0, 0, 0x0001 -bor 0x0004)
Start-Sleep -Milliseconds 600
$pr = New-Object UiCap+RECT; [void][UiCap]::GetWindowRect($pet, [ref]$pr)
# 卡片由 -Show 直接展开，不依赖模拟点击（桌宠是"按下即拖动"窗口，
# 快速 down/up 会被 50ms 轮询漏采，慢速 down/up 又会被判成拖动 → 截图链路不该依赖它）。
Start-Sleep -Milliseconds 1500
$card = [UiCap]::Find('看屏幕')
if ($card -eq [IntPtr]::Zero) { throw 'card not visible (run with -Show)' }
$cr = New-Object UiCap+RECT; [void][UiCap]::GetWindowRect($card, [ref]$cr)
$cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
"card-default = $($cr.Left),$($cr.Top) ${cw}x${ch}"
Save-Window $card 'card-v2-default.png'

# 2b) 滚到顶再拍一张：确认提问气泡与段落节奏
$vx = [int]($cr.Left + $cw / 2); $vy = [int]($cr.Top + $ch * 0.45)
[void][UiCap]::SetCursorPos($vx, $vy); Start-Sleep -Milliseconds 150
for ($i = 0; $i -lt 14; $i++) { [UiCap]::mouse_event(0x0800, 0, 0, 600, [IntPtr]::Zero); Start-Sleep -Milliseconds 50 }
Start-Sleep -Milliseconds 400
Save-Window $card 'card-v2-top.png'

# 2c) 把卡挪到桌面空白区再拍一张：排除别的窗口压在卡上（截图只取证版式，不动真实位置）
[void][UiCap]::SetWindowPos($card, [IntPtr]::Zero, 240, 60, 0, 0, 0x0001 -bor 0x0004)
Start-Sleep -Milliseconds 700
Save-Window $card 'card-v2-clean.png'


# 3) 改尺寸（模拟拖边框的最终结果），验证 Layout 重排不裁字
$nw = [int]($cw * 1.35); $nh = [int]($ch * 1.18)
$nx = [Math]::Max(40, $cr.Right - $nw); $ny = [Math]::Max(40, $cr.Top - 40)
[void][UiCap]::SetWindowPos($card, [IntPtr]::Zero, $nx, $ny, $nw, $nh, 0x0004)
Start-Sleep -Milliseconds 900
$r2 = New-Object UiCap+RECT; [void][UiCap]::GetWindowRect($card, [ref]$r2)
"card-resized = $($r2.Left),$($r2.Top) $($r2.Right - $r2.Left)x$($r2.Bottom - $r2.Top)"
Save-Window $card 'card-v2-wide.png'

# 4) 复原桌宠
[void][UiCap]::SetWindowPos($pet, [IntPtr]::Zero, 2134, 1098, 0, 0, 0x0001 -bor 0x0004)
'ui-capture done'
