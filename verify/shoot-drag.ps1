# 验证「拖动移动 / 拖边缩放 / 关掉再开沿用几何」三件事，全部用真实鼠标事件驱动。
# 旧版把缩放交给系统 WM_NCHITTEST + sizing loop，合成事件驱动不了模态循环；现在移动和缩放
# 都由卡片自己的 mouse 处理完成，注入事件即可驱动，因此可被脚本验证。
#
# 两个 PowerShell 坑（都踩过）：
#   1) EnumWindows 回调里的 scriptblock 不是闭包 —— 过滤字符串要用 $script: 作用域传进去；
#   2) 点桌宠的位置必须按「当下的」桌宠矩形算，它是会自己挪位置的。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;using System.Threading;
public class DragProbe {
  public delegate bool E(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(E cb, IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rr, B; }
  public static void Click(int x, int y) {
    SetCursorPos(x, y); Thread.Sleep(200);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); Thread.Sleep(140);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero); Thread.Sleep(800);
  }
  public static void Drag(int x1, int y1, int x2, int y2, int steps, int ms) {
    SetCursorPos(x1, y1); Thread.Sleep(200);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); Thread.Sleep(200);
    for (int i = 1; i <= steps; i++) { SetCursorPos(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps); Thread.Sleep(ms); }
    Thread.Sleep(200); mouse_event(0x0004, 0, 0, 0, IntPtr.Zero); Thread.Sleep(400);
  }
}
'@
[void][DragProbe]::SetProcessDPIAware()

$root = Split-Path -Parent $PSScriptRoot
$cardScript = Join-Path $root 'pet-chat.ps1'
$geom = Join-Path $env:USERPROFILE '.dsh\pet-chat\card.json'
$shots = Join-Path $PSScriptRoot 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

$script:Want = ''
$script:Exact = $false
$script:hit = [IntPtr]::Zero
$cb = [DragProbe+E]{
  param($h, $l)
  $t = New-Object Text.StringBuilder 300; [void][DragProbe]::GetWindowTextW($h, $t, 300); $s = $t.ToString()
  $ok = if ($script:Exact) { $s -eq $script:Want } else { $s.Contains($script:Want) }
  if ([DragProbe]::IsWindowVisible($h) -and $ok) { $script:hit = $h; return $false }
  return $true
}
function FindW([string]$Part, [bool]$Exact) {
  $script:Want = $Part; $script:Exact = $Exact; $script:hit = [IntPtr]::Zero
  [void][DragProbe]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:hit
}
function RectOf([IntPtr]$H) { $r = New-Object DragProbe+R; [void][DragProbe]::GetWindowRect($H, [ref]$r); return $r }
function Show4($R) { return ("{0},{1} {2}x{3}" -f $R.L, $R.T, ($R.Rr - $R.L), ($R.B - $R.T)) }
function Click-Pet {
  $pet = FindW 'Deepseek Harness Pet' $true
  if ($pet -eq [IntPtr]::Zero) { throw '找不到桌宠窗口' }
  $pr = RectOf $pet
  $x = [int](($pr.L + $pr.Rr) / 2)
  $y = [int]($pr.B - ($pr.B - $pr.T) * 0.35)
  [DragProbe]::Click($x, $y)
  return "$x,$y"
}

# 干净起步：杀掉旧卡、清掉几何记忆，拿默认位置。
# 只杀「以 -File <…>pet-chat.ps1 结尾」的进程：光匹配 pet-chat.ps1 会连调用本脚本的外层
# pwsh 一起杀掉（它的命令行里也含这个路径），表现为整个调用空输出、exit -1。
$selfPid = $PID
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $selfPid -and $_.CommandLine -match '-File\s+"?[^"]*pet-chat\.ps1"?\s*$' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
Start-Sleep -Milliseconds 700
if (Test-Path $geom) { Remove-Item $geom -Force }

Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $cardScript) | Out-Null
Start-Sleep -Seconds 3

$hitPt = Click-Pet
$h = FindW '看屏幕' $false
if ($h -eq [IntPtr]::Zero) { throw "点桌宠（$hitPt）后卡片没弹出来" }
$r0 = RectOf $h
"r0 summon   = $(Show4 $r0)"

# 1) 拖标题栏 → 移动（往左下挪；默认位就在右缘，往右拖会被虚拟桌面夹住，看不出位移）
[DragProbe]::Drag(($r0.L + 120), ($r0.T + 40), ($r0.L + 120 - 700), ($r0.T + 40 + 80), 14, 45)
Start-Sleep -Milliseconds 300
$r1 = RectOf $h
"r1 moved    = $(Show4 $r1)   d=+$($r1.L - $r0.L),+$($r1.T - $r0.T)"

# 2) 拖右下角 → 同时改宽高（落在圆角内侧 10px：圆角外的像素根本不属于窗口，点了会穿过去）
[DragProbe]::Drag(($r1.Rr - 10), ($r1.B - 10), ($r1.Rr - 10 + 160), ($r1.B - 10 + 120), 14, 45)
Start-Sleep -Milliseconds 300
$r2 = RectOf $h
"r2 size BR  = $(Show4 $r2)   d=+$(($r2.Rr - $r2.L) - ($r1.Rr - $r1.L)),+$(($r2.B - $r2.T) - ($r1.B - $r1.T))"

# 3) 左缘 / 下缘各拖一次 → 单独改宽、单独改高
[DragProbe]::Drag(($r2.L + 10), ($r2.B - 300), ($r2.L + 10 - 80), ($r2.B - 300), 8, 45)
$r3 = RectOf $h
"r3 size L   = $(Show4 $r3)   dW=+$(($r3.Rr - $r3.L) - ($r2.Rr - $r2.L))"
[DragProbe]::Drag(($r3.L + 200), ($r3.B - 10), ($r3.L + 200), ($r3.B - 10 - 100), 8, 45)
$r4 = RectOf $h
"r4 size B   = $(Show4 $r4)   dH=+$(($r4.B - $r4.T) - ($r3.B - $r3.T))"

$bmp = New-Object Drawing.Bitmap (($r4.Rr - $r4.L), ($r4.B - $r4.T))
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r4.L, $r4.T, 0, 0, $bmp.Size)
$g.Dispose(); $bmp.Save((Join-Path $shots 'card-v3-moved.png')); $bmp.Dispose()
"shot        = shots\card-v3-moved.png"

# 4) 藏起来再弹出来 → 位置和大小都该沿用
[void](Click-Pet)
Start-Sleep -Milliseconds 500
[void](Click-Pet)
Start-Sleep -Milliseconds 900
$r5 = RectOf $h
$same = ($r5.L -eq $r4.L -and $r5.T -eq $r4.T -and ($r5.Rr - $r5.L) -eq ($r4.Rr - $r4.L) -and ($r5.B - $r5.T) -eq ($r4.B - $r4.T))
"r5 reopened = $(Show4 $r5)   persisted=$same"
"card.json   = $(if (Test-Path $geom) { (Get-Content $geom -Raw).Trim() } else { '<missing>' })"
'drag-test done'
