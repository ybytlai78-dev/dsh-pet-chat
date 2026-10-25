#requires -Version 5.1
param([switch]$Show, [switch]$Demo)   # -Show 启动即展开；-Demo 塞一段样例问答（都只给验证脚本用）
<#
  dsh-pet-chat —— 挂在官方桌宠上的聊天卡（Windows / PowerShell + WinForms，无第三方依赖）

  平时完全隐藏：屏幕上只有 dsh-tauri-pet 的鲸鱼娘。
  点一下那只鲸鱼娘 → 这张卡停靠在屏幕右侧固定位置（可拖标题栏挪、可拖边框改大小）。
  在卡里输入问题 → 回车 → 卡自己抓当前屏幕（不含自己）→ 发进当前 dsh 会话 → 轮询回显答案。

  为什么不改官方桌宠：pet 窗口是 Tauri 壳内嵌页面（title "Deepseek Harness Pet"），
  插件层拿不到它的 DOM 与点击事件（dsh-tauri 只导出工具函数，无窗口 API）。
  所以这里用「轮询光标 + 左键松开且位移<8px + 命中宠物窗口热点区」判定为点桌宠。

  契约见 DESIGN.md；宿主半边是 lib/index.js。
  端口与 token 从 $DSH_HOME\pet-chat\endpoint.json 读取（插件启动时写入）。
  卡片位置/大小记在 $DSH_HOME\pet-chat\card.json。
#>

$ErrorActionPreference = 'Stop'

# 单实例：桌宠只该有一张卡。第二个实例直接退出，避免两张卡叠在一起互相压字。
$script:Mutex = New-Object Threading.Mutex($false, 'Local\dsh-pet-chat-card')
if (-not $script:Mutex.WaitOne(0)) { return }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 声明 DPI 感知：不声明的话 200% 屏上窗口被位图拉伸 → 字发糊（旧版"很糊"的根因）。
# 感知之后所有像素几何都必须乘 $k = DPI/96，否则字放大、按钮装不下（历史 bug）。
Add-Type @'
using System.Runtime.InteropServices;
public static class DpiNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  // 让系统控件（滚动条等）走深色：uxtheme 私有序号 API，Win10 1903+ / Win11 有效。
  [DllImport("uxtheme.dll", EntryPoint = "#135")] public static extern int SetPreferredAppMode(int mode);
  [DllImport("uxtheme.dll", EntryPoint = "#136")] public static extern void FlushMenuThemes();
}
'@
[void][DpiNative]::SetProcessDPIAware()
# 浅色主题下不需要强制深色系统控件；原生滚动条已在 RichTextBox 上关掉，故不再调 uxtheme。
[System.Windows.Forms.Application]::EnableVisualStyles()

# WinForms 类型（NativeWindow / Message）不在默认引用集里，必须显式引用这两个程序集。
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class PetWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  // 深色滚动条：Win10 1809+ 的 uxtheme 认这个主题名，改完 RichTextBox 的滚动条不再是亮灰。
  [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string idlist);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  // 官方桌宠窗：class=Tauri Window，title 含 "Pet"，且属于壳进程。
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
}

// 无边框窗口靠 WM_NCHITTEST 让系统自己处理拖边缩放（光标、吸附、DPI 都由系统负责）。
public class ResizeHook : NativeWindow {
  public System.Windows.Forms.Form Target;
  public int Grip = 8;
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x84 && Target != null) {          // WM_NCHITTEST
      int sx = (short)((long)m.LParam & 0xFFFF);
      int sy = (short)(((long)m.LParam >> 16) & 0xFFFF);
      var p = Target.PointToClient(new System.Drawing.Point(sx, sy));
      int w = Target.ClientSize.Width, h = Target.ClientSize.Height;
      bool left = p.X < Grip, right = p.X > w - Grip, top = p.Y < Grip, bottom = p.Y > h - Grip;
      int hit = 0;
      if (top && left) hit = 13;
      else if (top && right) hit = 14;
      else if (bottom && left) hit = 16;
      else if (bottom && right) hit = 17;
      else if (left) hit = 10;
      else if (right) hit = 11;
      else if (top) hit = 12;
      else if (bottom) hit = 15;
      if (hit != 0) { m.Result = (IntPtr)hit; return; }
    }
    base.WndProc(ref m);
  }
}
'@

# ── 消息视图（自绘）：样式与几何照设计稿，避开 RichTextBox 行距不可控 ──────────
$msgViewCs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'msgview.cs'))
Add-Type -TypeDefinition $msgViewCs -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'

# ── 路径与状态 ───────────────────────────────────────────────────────────────
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$StateDir = Join-Path $DshHome 'pet-chat'
$EndpointFile = Join-Path $StateDir 'endpoint.json'
$GeomFile = Join-Path $StateDir 'card.json'
$LogFile = Join-Path $StateDir 'watcher.log'

$script:Base = $null
$script:Token = $null
$script:SessionId = ''
# 刚点了「新建会话」：还没有标题，先把标题位显示成「新会话」，别闪回品牌名。
$script:FreshSession = $false
$script:Suppress = $false
$script:LastText = ''
$script:LastStatus = ''
$script:DownPoint = $null
$script:CardOpen = $false
$script:Pending = $null
$script:BootIdle = $true
$script:StatusKind = 'idle'
$script:StatusText = ''

function Trace {
  param([string]$Message)
  try { Add-Content -LiteralPath $LogFile -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $Message) -Encoding UTF8 } catch { }
}

# ── 调色板：取自 design-demos\d2-overlay.html 的 token（Raycast 浮层语言）─────
$cCanvas      = [Drawing.Color]::FromArgb(255, 255, 255)   # 卡面 #FFFFFF
$cSurface     = [Drawing.Color]::FromArgb(245, 249, 255)   # 顶栏 #F5F9FF
$cFoot        = [Drawing.Color]::FromArgb(248, 251, 255)   # 底栏 #F8FBFF
$cInset       = [Drawing.Color]::FromArgb(251, 253, 255)   # 输入框内底 #FBFDFF
$cEdge        = [Drawing.Color]::FromArgb(168, 191, 221)   # 卡片外框 #A8BFDD
$cLine        = [Drawing.Color]::FromArgb(217, 228, 243)   # 发丝线 #D9E4F3
$cLineStrong  = [Drawing.Color]::FromArgb(195, 212, 234)   # 输入框描边 #C3D4EA
$cText        = [Drawing.Color]::FromArgb(28, 40, 58)      # 正文 #1C283A
$cMuted       = [Drawing.Color]::FromArgb(94, 112, 137)    # 次要文字 #5E7089
$cAccent      = [Drawing.Color]::FromArgb(37, 96, 240)     # 强调蓝 #2560F0
$cAccentPress = [Drawing.Color]::FromArgb(30, 83, 216)     # 按下 #1E53D8
$cBubble      = [Drawing.Color]::FromArgb(232, 240, 254)   # 提问气泡底 #E8F0FE
$cBubbleInk   = [Drawing.Color]::FromArgb(23, 53, 111)     # 提问文字 #17356F
$cOk          = [Drawing.Color]::FromArgb(47, 158, 106)    # 在线点 #2F9E6A
$cBusy        = [Drawing.Color]::FromArgb(192, 128, 48)    # 思考中（暖色）
$cBad         = [Drawing.Color]::FromArgb(168, 64, 44)     # 出错文字 #A8402C
$cBadBg       = [Drawing.Color]::FromArgb(253, 241, 238)   # 出错块底 #FDF1EE
$cBadLine     = [Drawing.Color]::FromArgb(239, 211, 203)   # 出错块描边 #EFD3CB
$cTrack       = [Drawing.Color]::FromArgb(228, 237, 250)   # 进度轨 #E4EDFA
$cThumb       = [Drawing.Color]::FromArgb(157, 190, 240)   # 进度滑块 #9DBEF0

# ── DPI 缩放：字号用 pt（系统按 DPI 换算），像素几何全部乘 $k ─────────────────
$script:K = 1.0
function S { param([double]$v) [int][Math]::Round($v * $script:K) }
function F { param([double]$pt, [bool]$bold = $false)
  if ($bold) { return New-Object Drawing.Font('Microsoft YaHei UI', $pt, [Drawing.FontStyle]::Bold) }
  return New-Object Drawing.Font('Microsoft YaHei UI', $pt)
}

# 设计稿字号：正文 14px=10.5pt、辅助 12px=9pt、按钮 14px/600=10.5pt 粗体。
# 设计稿字号（逻辑像素）：正文 14、辅助 12、按钮 14/600。
# 但本机 GDI 给 CJK 的实际前进宽度是请求像素的 ~1.53 倍（系统文本缩放），
# 直接照 pt 建字体会让每行只剩 13 个字。这里按"量一个汉字的宽度再反解字号"，
# 保证 420 宽的卡上一行仍是设计稿的 ~27 字。
function Fit-Font {
  param([double]$AdvancePx, [bool]$Bold = $false)
  $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
  $size = [Math]::Max($AdvancePx, 6)
  $flags = [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::SingleLine
  $f = $null
  for ($i = 0; $i -lt 4; $i++) {
    if ($f) { $f.Dispose() }
    $f = New-Object Drawing.Font('Microsoft YaHei UI', [single]$size, $style, [Drawing.GraphicsUnit]::Pixel)
    $w = [Windows.Forms.TextRenderer]::MeasureText('先', $f, (New-Object Drawing.Size(32767, 32767)), $flags).Width
    if ($w -le 0) { break }
    $size = $size * ($AdvancePx / $w)
  }
  return $f
}

$script:FontsK = -1   # 字体按当时的 DPI 反解过；K 变了必须重建（否则会停在首帧的 96dpi）
$fTitle = F 10.5 $true
$fBody = F 10.5
$fMeta = F 9
$fBtn = F 10.5 $true
$fTiny = F 6

function Make-Fonts {
  if ($script:FontsK -ne $script:K) {
    # 首次在这里重建（K 已按真实 DPI 算好），之后只读缓存。
    $script:fTitle = Fit-Font (16 * $script:K) $true
    $script:fBody = Fit-Font (16 * $script:K)
    $script:fMeta = Fit-Font (13 * $script:K)
    $script:fBtn = Fit-Font (15 * $script:K) $true
    $script:FontsK = $script:K
  }
  $lblTitle.Font = $script:fTitle
  $txtInput.Font = $script:fBody
  $lblPlaceholder.Font = $script:fBody
  $lblHint.Font = $script:fMeta
  $btnLook.Font = $script:fBtn
}

# ── 接口 ─────────────────────────────────────────────────────────────────────
function Read-Endpoint {
  if (-not (Test-Path -LiteralPath $EndpointFile)) { return $false }
  try {
    $ep = Get-Content -LiteralPath $EndpointFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $ep.base -or -not $ep.token) { return $false }
    $script:Base = [string]$ep.base
    $script:Token = [string]$ep.token
    return $true
  } catch { return $false }
}

function Invoke-Api {
  param([string]$Method, [string]$Path, $Body)
  if (-not $script:Base) { return $null }
  $headers = @{ 'x-pet-token' = $script:Token }
  try {
    if ($null -ne $Body) {
      $json = $Body | ConvertTo-Json -Depth 6 -Compress
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      $resp = Invoke-WebRequest -Uri ($script:Base + $Path) -Method $Method -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing -TimeoutSec 120
    } else {
      $resp = Invoke-WebRequest -Uri ($script:Base + $Path) -Method $Method -Headers $headers `
        -UseBasicParsing -TimeoutSec 20
    }
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    return ($text | ConvertFrom-Json)
  } catch { return $null }
}

# 抓屏前先把自己藏起来，否则把自己也拍进画面（宠物是别人的窗口，照常留在画面里）。
function Get-ShotBase64 {
  $wasOpen = $script:CardOpen
  if ($wasOpen) { $form.Hide(); Start-Sleep -Milliseconds 180 }
  try {
    $bounds = [Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bmp)
    try { $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size) } finally { $graphics.Dispose() }
    $ms = New-Object IO.MemoryStream
    try { $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return [Convert]::ToBase64String($bytes)
  } finally {
    if ($wasOpen) { $form.Show() }
  }
}

function Set-RoundRegion {
  param($Form, [int]$Radius)
  $d = $Radius * 2
  if ($Form.Width -le $d -or $Form.Height -le $d) { return }
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $w = $Form.Width; $h = $Form.Height
  $path.AddArc(0, 0, $d, $d, 180, 90)
  $path.AddArc($w - $d, 0, $d, $d, 270, 90)
  $path.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
  $path.AddArc(0, $h - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $old = $Form.Region
  $Form.Region = New-Object Drawing.Region($path)
  if ($old) { $old.Dispose() }
  $path.Dispose()
}

function Set-EllipseRegion {
  param($Control)
  if ($Control.Width -le 2 -or $Control.Height -le 2) { return }
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $path.AddEllipse(0, 0, $Control.Width, $Control.Height)
  $old = $Control.Region
  $Control.Region = New-Object Drawing.Region($path)
  if ($old) { $old.Dispose() }
  $path.Dispose()
}

# ── 窗体骨架 ─────────────────────────────────────────────────────────────────
$form = New-Object Windows.Forms.Form
$form.Text = '鲸鱼娘 · 看屏幕'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = $cCanvas
$form.AutoScaleMode = 'None'

# ── 标题栏 ───────────────────────────────────────────────────────────────────
$header = New-Object Windows.Forms.Panel
$header.BackColor = $cSurface

$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = '鲸鱼娘'
$lblTitle.AutoSize = $false
$lblTitle.TextAlign = 'MiddleLeft'
$lblTitle.AutoEllipsis = $true
$lblTitle.ForeColor = $cText
$lblTitle.Font = $fTitle
$lblTitle.BackColor = [Drawing.Color]::Transparent

$lblDot = New-Object Windows.Forms.Label
$lblDot.Text = '●'
$lblDot.AutoSize = $false
$lblDot.TextAlign = 'MiddleCenter'
$lblDot.ForeColor = $cMuted
$lblDot.Font = $fMeta
$lblDot.BackColor = [Drawing.Color]::Transparent

function New-Glyph {
  param([string]$Glyph)
  $g = New-Object Windows.Forms.Label
  $g.Text = $Glyph
  $g.AutoSize = $false
  $g.TextAlign = 'MiddleCenter'
  $g.ForeColor = $cMuted
  $g.BackColor = [Drawing.Color]::Transparent
  $g.Font = F 11
  $g.Cursor = [Windows.Forms.Cursors]::Hand
  $g.Add_MouseEnter({ param($s, $e) $s.ForeColor = $cText })
  $g.Add_MouseLeave({ param($s, $e) $s.ForeColor = $cMuted })
  return $g
}
$btnHide = New-Glyph '—'
$btnClose = New-Glyph '×'

$header.Controls.AddRange(@($lblTitle, $lblDot, $btnHide, $btnClose))

# 顶栏底线 / 底栏顶线：设计稿里只靠这两条 1px 线分区，不要整块底色。
$hLine = New-Object Windows.Forms.Panel
$hLine.BackColor = $cLine
$hLine.Height = 1
$footLine = New-Object Windows.Forms.Panel
$footLine.BackColor = $cLine
$footLine.Height = 1

# ── 消息流：自绘控件（msgview.cs），提问右对齐气泡、回答左对齐正文 ────────────
$script:Msgs = New-Object 'System.Collections.Generic.List[object]'

$view = New-Object PetMsgView
$view.BackColor = $cCanvas
$view.CText = $cText
$view.CMuted = $cMuted
$view.CBubble = $cBubble
$view.CBubbleInk = $cBubbleInk
$view.CTrack = $cTrack
$view.CThumb = $cThumb
$view.CBadBg = $cBadBg
$view.CBadLine = $cBadLine
$view.CBadInk = $cBad

function Sync-View {
  # 行高/内边距按当前 DPI 重算（Layout 与 Show-Card 后都会调）。
  if (-not $view) { return }
  try { $view.Configure([single]($script:K), $fBody, $fMeta) } catch { }
}

function Render-Msgs {
  $arr = [PetMsgView+Msg[]]::new($script:Msgs.Count)
  for ($i = 0; $i -lt $script:Msgs.Count; $i++) { $arr[$i] = $script:Msgs[$i] }
  $view.Reset($arr)
}

function Update-Rail { try { $view.Invalidate() } catch { } }

# ── 输入区 ───────────────────────────────────────────────────────────────────
$inputWrap = New-Object Windows.Forms.Panel
$inputWrap.BackColor = $cFoot

$txtInput = New-Object Windows.Forms.TextBox
$txtInput.Multiline = $false
$txtInput.BorderStyle = 'None'
$txtInput.BackColor = $cInset  # 几乎纯白 + 淡蓝描边 = 一眼看出是输入框
$txtInput.ForeColor = $cText
$txtInput.Font = $fBody

# TextBox 自己画不了边框，用一层 1px 的浅蓝面板当描边。
$inputFrame = New-Object Windows.Forms.Panel
$inputFrame.BackColor = $cLineStrong
$inputInner = New-Object Windows.Forms.Panel
$inputInner.BackColor = $cInset
$inputInner.Controls.Add($txtInput)

# 占位提示：单行 TextBox 自己画不了，用一层 Label 叠在输入框上，有字或聚焦时隐藏。
$lblPlaceholder = New-Object Windows.Forms.Label
$lblPlaceholder.Text = '写点问题，Enter 发送'
$lblPlaceholder.AutoSize = $false
$lblPlaceholder.BackColor = $cInset
$lblPlaceholder.ForeColor = $cMuted
$lblPlaceholder.Font = $fBody
$lblPlaceholder.TextAlign = 'MiddleLeft'
$lblPlaceholder.Cursor = [Windows.Forms.Cursors]::IBeam
$inputInner.Controls.Add($lblPlaceholder)
$lblPlaceholder.BringToFront()
$inputFrame.Controls.Add($inputInner)

$lblHint = New-Object Windows.Forms.Label
$lblHint.Text = 'Enter 发送 · Shift+Enter 换行'
$lblHint.AutoSize = $false
$lblHint.TextAlign = 'MiddleLeft'
$lblHint.ForeColor = $cMuted
$lblHint.Font = $fMeta
$lblHint.BackColor = [Drawing.Color]::Transparent

function New-FlatButton {
  param([string]$Label, [bool]$Primary)
  $b = New-Object Windows.Forms.Button
  $b.Text = $Label
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.Font = $fBtn
  $b.Cursor = [Windows.Forms.Cursors]::Hand
  $b.UseVisualStyleBackColor = $false
  if ($Primary) {
    $b.BackColor = $cAccent
    $b.ForeColor = [Drawing.Color]::White
    $b.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(51, 106, 242)
    $b.FlatAppearance.MouseDownBackColor = $cAccentPress
  } else {
    $b.BackColor = $cCanvas
    $b.ForeColor = $cBubbleInk
    $b.FlatAppearance.MouseOverBackColor = $cSurface
    $b.FlatAppearance.MouseDownBackColor = $cLine
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $cLineStrong
  }
  return $b
}

# 主操作：圆形图标按钮（蓝底 + 白色向上箭头）＝ 只发问题、不抓屏。
# 设计稿里的文字主按钮被它替代；抓屏提问降级成左边的 ghost 按钮。
$btnAsk = New-Object Windows.Forms.Panel
$btnAsk.BackColor = $cAccent
$btnAsk.Cursor = [Windows.Forms.Cursors]::Hand
$btnAsk.Add_Paint({
    param($src, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $k = $script:K
    $w = $src.ClientSize.Width; $h = $src.ClientSize.Height
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, [single][Math]::Max((2 * $k), 2))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $cx = $w / 2.0; $cy = $h / 2.0
    $shaft = [single](6 * $k); $headW = [single](5 * $k); $headH = [single](1 * $k)
    $e.Graphics.DrawLine($pen, [single]$cx, ($cy + $shaft), [single]$cx, ($cy - $shaft))
    $e.Graphics.DrawLine($pen, [single]($cx - $headW), ($cy - $headH), [single]$cx, ($cy - $shaft))
    $e.Graphics.DrawLine($pen, [single]($cx + $headW), ($cy - $headH), [single]$cx, ($cy - $shaft))
    $pen.Dispose()
  })
$btnAsk.Add_MouseEnter({ $btnAsk.BackColor = [Drawing.Color]::FromArgb(51, 106, 242) })
$btnAsk.Add_MouseLeave({ $btnAsk.BackColor = $cAccent })

$btnLook = New-FlatButton '看屏幕并提问' $false

$inputWrap.Controls.AddRange(@($inputFrame, $lblHint, $btnAsk, $btnLook))

# 工作区条：左边选工作区，右边新建会话（预设不传 = 走部署默认）。
$wsBar = New-Object Windows.Forms.Panel
$wsBar.BackColor = $cSurface
$wsLine = New-Object Windows.Forms.Panel
$wsLine.BackColor = $cLine
$wsLine.Height = 1

$cmbWs = New-Object Windows.Forms.ComboBox
$cmbWs.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$cmbWs.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$cmbWs.Font = $fMeta
$cmbWs.BackColor = $cCanvas
$cmbWs.ForeColor = $cText
$cmbWs.Cursor = [Windows.Forms.Cursors]::Hand
$wsBar.Controls.Add($cmbWs)

$btnNew = New-FlatButton '新建会话' $false
$btnNew.Font = $fMeta
$wsBar.Controls.Add($btnNew)

$form.Controls.AddRange(@($header, $hLine, $wsBar, $wsLine, $view, $footLine, $inputWrap))

# ── 布局：唯一一处算几何，Resize 时重算 ──────────────────────────────────────
function Layout {
  try { Make-Fonts } catch { }
  $pad = S 14
  $hH = S 44
  $wsH = S 34
  $w = $form.ClientSize.Width
  $h = $form.ClientSize.Height

  $header.Location = New-Object Drawing.Point(0, 0)
  $header.Size = New-Object Drawing.Size($w, $hH)

  $glyph = S 30
  $gTop = [int](($hH - (S 28)) / 2)
  $btnClose.Size = New-Object Drawing.Size($glyph, (S 28))
  $btnClose.Location = New-Object Drawing.Point(($w - $pad - $glyph), $gTop)
  $btnHide.Size = New-Object Drawing.Size($glyph, (S 28))
  $btnHide.Location = New-Object Drawing.Point(($w - $pad - $glyph * 2 - (S 4)), $gTop)
  $lblDot.Size = New-Object Drawing.Size((S 14), $hH)
  $lblDot.Location = New-Object Drawing.Point(($w - $pad - $glyph * 2 - (S 24)), 0)
  $lblTitle.Location = New-Object Drawing.Point($pad, 0)
  $lblTitle.Size = New-Object Drawing.Size([Math]::Max(($w - $pad * 2 - $glyph * 2 - (S 44)), (S 80)), $hH)

  # 底栏几何照设计稿：padding 12/14/14 + 输入框 42 + 间隙 9 + 动作行 32。
  $padX = S 14
  $padT = S 12
  $fieldH = S 42
  $btnH = S 32
  $iconD = S 38
  $actsH = $iconD
  $footH = $padT + $fieldH + (S 9) + $actsH + (S 14)

  $bodyH = $h - $hH - $wsH - $footH
  if ($bodyH -lt (S 80)) { $bodyH = S 80 }

  $hLine.Location = New-Object Drawing.Point(0, ($hH - 1))
  $hLine.Size = New-Object Drawing.Size($w, 1)

  $wsBar.Location = New-Object Drawing.Point(0, $hH)
  $wsBar.Size = New-Object Drawing.Size($w, $wsH)
  $cmbRowH = S 24
  $cmbY = [int](($wsH - $cmbRowH) / 2)
  $newW = S 86
  $cmbWs.Location = New-Object Drawing.Point($pad, $cmbY)
  $cmbWs.Size = New-Object Drawing.Size([Math]::Max(($w - $pad * 2 - $newW - (S 8)), (S 120)), $cmbRowH)
  $btnNew.Location = New-Object Drawing.Point(($w - $pad - $newW), $cmbY)
  $btnNew.Size = New-Object Drawing.Size($newW, $cmbRowH)
  $wsLine.Location = New-Object Drawing.Point(0, ($wsH - 1))
  $wsLine.Size = New-Object Drawing.Size($w, 1)

  $view.Location = New-Object Drawing.Point(0, ($hH + $wsH))
  $view.Size = New-Object Drawing.Size($w, $bodyH)

  $inputWrap.Location = New-Object Drawing.Point(0, ($hH + $wsH + $bodyH))
  $inputWrap.Size = New-Object Drawing.Size($w, $footH)
  $footLine.Location = New-Object Drawing.Point(0, 0)
  $footLine.Size = New-Object Drawing.Size($w, 1)

  $innerW = $w - $padX * 2
  $inputFrame.Location = New-Object Drawing.Point($padX, $padT)
  $inputFrame.Size = New-Object Drawing.Size($innerW, $fieldH)
  $inputInner.Location = New-Object Drawing.Point(1, 1)
  $inputInner.Size = New-Object Drawing.Size(($innerW - 2), ($fieldH - 2))
  $txtInput.Location = New-Object Drawing.Point((S 12), (S 8))
  $txtInput.Size = New-Object Drawing.Size([Math]::Max(($innerW - (S 26)), (S 60)), (S 26))
  $lblPlaceholder.Location = New-Object Drawing.Point((S 13), (S 8))
  $lblPlaceholder.Size = New-Object Drawing.Size([Math]::Max(($innerW - (S 28)), (S 60)), (S 26))

  # 按钮的父是 $inputWrap，坐标必须相对它算（用窗体坐标会被父面板裁掉）。
  $lookW = S 116
  $btnY = $padT + $fieldH + (S 9)
  $btnAsk.Size = New-Object Drawing.Size($iconD, $iconD)
  $btnAsk.Location = New-Object Drawing.Point(($w - $padX - $iconD), $btnY)
  $btnLook.Size = New-Object Drawing.Size($lookW, $btnH)
  $btnLook.Location = New-Object Drawing.Point(($w - $padX - $iconD - (S 10) - $lookW),
                                               ($btnY + [int](($iconD - $btnH) / 2)))

  # 状态行与动作行同排（左端），不额外占高度。
  $lblHint.Location = New-Object Drawing.Point($padX, ($btnY + [int](($iconD - $btnH) / 2)))
  $lblHint.Size = New-Object Drawing.Size(
    [Math]::Max(($w - $padX * 2 - $iconD - $lookW - (S 32)), (S 60)), $btnH)

  Set-RoundRegion $form (S 12)
  Set-RoundRegion $inputFrame (S 8)
  Set-EllipseRegion $btnAsk
  Set-RoundRegion $btnLook (S 7)
  try { Sync-View } catch { }
}

# ── 消息渲染 ─────────────────────────────────────────────────────────────────
# ponytail: 极简 markdown 扁平化（去围栏、标题变引块、压空行），只为"读得下去"，
# 不做行内加粗/列表缩进；真排版需求再上 RichTextBox 的 rtf 分段。
function Format-Text {
  param([string]$Text)
  if (-not $Text) { return '' }
  $body = $Text -replace "`r", ''
  if ($body.Length -gt 4000) { $body = "…（前文过长已截断）`n" + $body.Substring($body.Length - 4000) }
  $lines = $body -split "`n"
  $sb = New-Object System.Text.StringBuilder
  foreach ($ln in $lines) {
    $s = $ln.TrimEnd()
    if ($s -match '^\s*```') { continue }
    if ($s -match '^\s*#{1,6}\s+(.+)$') { $s = '▍ ' + $matches[1] }
    $s = $s -replace '^\s*[-*]\s+', '· '
    # 自绘视图只认纯文本：图片语法整段丢掉，链接留文字，行内代码/加粗只留内容。
    $s = $s -replace '!\[[^\]]*\]\([^)]*\)', ''
    $s = $s -replace '\[([^\]]*)\]\([^)]*\)', '$1'
    $s = $s -replace '`([^`]*)`', '$1'
    $s = $s -replace '\*\*([^*]+)\*\*', '$1'
    $s = $s -replace '__([^_]+)__', '$1'
    if ($s.Trim() -eq '') { [void]$sb.Append("`n"); continue }
    [void]$sb.Append($s + "`n")
  }
  ($sb.ToString() -replace "`n{3,}", "`n`n").Trim()
}

function Add-Bubble {
  param([string]$Text, [string]$Meta, [string]$Kind = 'theirs')
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  $m = New-Object 'PetMsgView+Msg'
  $m.Kind = $Kind
  $m.Text = Format-Text $Text
  $m.Meta = $Meta
  [void]$script:Msgs.Add($m)
  Render-Msgs
  if ($Kind -eq 'mine') { Write-CardLog ('view: ' + $view.Dump()) }
}

# 出错不是弹一句就走：设计稿把提示做成块，留在流里可回看。
function Add-Notice {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  if ($script:Msgs.Count -gt 0) {
    $last = $script:Msgs[$script:Msgs.Count - 1]
    if ($last.Kind -eq 'error' -and $last.Text -eq $Text) { return }
  }
  $m = New-Object 'PetMsgView+Msg'
  $m.Kind = 'error'
  $m.Text = $Text
  [void]$script:Msgs.Add($m)
  Render-Msgs
}

function Show-EmptyState {
  $script:Msgs.Clear()
  $m = New-Object 'PetMsgView+Msg'
  $m.Kind = 'empty'
  $m.Text = "点我提问。我会自己看你此刻的屏幕，把问题和一帧截图送进 dsh 当前会话；左下角能换工作区、建新会话。`n`n" +
    "· 输入问题后按 Enter`n" +
    "· 只想让它再看一眼，按「只发屏幕」`n" +
    "· 点鲸鱼娘可以再次收起这张卡"
  [void]$script:Msgs.Add($m)
  Render-Msgs
}

function Now-Meta { (Get-Date).ToString('HH:mm') }

# ── 几何记忆 ─────────────────────────────────────────────────────────────────
function Default-Geometry {
  $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $w = [Math]::Min((S 420), [int]($area.Width * 0.9))
  $h = [Math]::Min((S 620), [int]($area.Height * 0.92))
  $x = $area.Right - $w - (S 24)
  $y = $area.Top + [int](($area.Height - $h) / 2)
  return @{ x = $x; y = $y; w = $w; h = $h }
}

function Load-Geometry {
  if (Test-Path -LiteralPath $GeomFile) {
    try {
      $g = Get-Content -LiteralPath $GeomFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($g.w -gt 200 -and $g.h -gt 200) {
        return @{ x = [int]$g.x; y = [int]$g.y; w = [int]$g.w; h = [int]$g.h }
      }
    } catch { }
  }
  return (Default-Geometry)
}

function Save-Geometry {
  try {
    @{ x = $form.Left; y = $form.Top; w = $form.Width; h = $form.Height } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $GeomFile -Encoding UTF8
  } catch { }
}

function Show-Card {
  $script:K = $form.CreateGraphics().DpiX / 96.0
  $g = Load-Geometry
  # 用虚拟桌面而不是主屏：卡被拖到副屏时不该被拉回来。
  $area = [Windows.Forms.SystemInformation]::VirtualScreen
  $w = [Math]::Max([Math]::Min($g.w, $area.Width), (S 360))
  $h = [Math]::Max([Math]::Min($g.h, $area.Height), (S 420))
  $x = [Math]::Max([Math]::Min($g.x, $area.Right - $w), $area.Left)
  $y = [Math]::Max([Math]::Min($g.y, $area.Bottom - $h), $area.Top)

  $form.MinimumSize = New-Object Drawing.Size((S 360), (S 420))
  $form.Bounds = New-Object Drawing.Rectangle($x, $y, $w, $h)
  Layout
  $form.Show()
  $form.TopMost = $true
  [void]$form.Activate()
  $txtInput.Focus() | Out-Null
  $script:CardOpen = $true
}

function Hide-Card {
  $script:CardOpen = $false
  Save-Geometry
  $form.Hide()
}

$btnHide.Add_Click({ Hide-Card })
$btnClose.Add_Click({ Hide-Card })

# ── 拖动 / 缩放 ──────────────────────────────────────────────────────────────
# 只在 Form 上拦 WM_NCHITTEST 是行不通的：header、消息区、输入区都是子窗口，
# 鼠标命中的是子控件，系统 hit-test 根本到不了窗体边框 —— 表现就是"只能左右拉宽、
# 拖不动"。所以移动和缩放都自己实现：在每个子控件上也挂一套 mouse 处理。
$script:DragOp = $null
$script:Movable = @{}

function Get-Zone {
  param([Drawing.Point]$ScreenPt)
  $b = $form.Bounds
  # 12px 而不是 8px：窗口有 14px 圆角，圆角外的像素不属于窗口，鼠标会直接穿过去，
  # 抓角必须落在圆角内侧一点，边带太窄就"看得见抓不到"。
  $t = [Math]::Max((S 12), 8)
  $z = ''
  if ($ScreenPt.Y - $b.Top -le $t) { $z += 't' }
  elseif ($b.Bottom - $ScreenPt.Y -le $t) { $z += 'b' }
  if ($ScreenPt.X - $b.Left -le $t) { $z += 'l' }
  elseif ($b.Right - $ScreenPt.X -le $t) { $z += 'r' }
  return $z
}

function Zone-Cursor {
  param([string]$Zone, [bool]$Movable)
  switch ($Zone) {
    'tl' { return [Windows.Forms.Cursors]::SizeNWSE }
    'br' { return [Windows.Forms.Cursors]::SizeNWSE }
    'tr' { return [Windows.Forms.Cursors]::SizeNESW }
    'bl' { return [Windows.Forms.Cursors]::SizeNESW }
    'l' { return [Windows.Forms.Cursors]::SizeWE }
    'r' { return [Windows.Forms.Cursors]::SizeWE }
    't' { return [Windows.Forms.Cursors]::SizeNS }
    'b' { return [Windows.Forms.Cursors]::SizeNS }
    default { if ($Movable) { return [Windows.Forms.Cursors]::SizeAll } else { return [Windows.Forms.Cursors]::Default } }
  }
}

function Update-Drag {
  param([Drawing.Point]$ScreenPt)
  $d = $script:DragOp
  if ($null -eq $d) { return }
  $dx = $ScreenPt.X - $d.StartPt.X
  $dy = $ScreenPt.Y - $d.StartPt.Y
  $b = $d.Bounds
  if ($d.Mode -eq 'move') {
    $l = $b.Left + $dx; $t = $b.Top + $dy; $w = $b.Width; $h = $b.Height
  } else {
    $minW = (S 360); $minH = (S 420)
    $l = $b.Left; $t = $b.Top; $w = $b.Width; $h = $b.Height
    $z = [string]$d.Zone
    if ($z.Contains('l')) {
      $nl = [Math]::Min($b.Left + $dx, ($b.Right - $minW))
      $l = $nl; $w = $b.Right - $nl
    }
    if ($z.Contains('r')) { $w = [Math]::Max($minW, $b.Width + $dx) }
    if ($z.Contains('t')) {
      $nt = [Math]::Min($b.Top + $dy, ($b.Bottom - $minH))
      $t = $nt; $h = $b.Bottom - $nt
    }
    if ($z.Contains('b')) { $h = [Math]::Max($minH, $b.Height + $dy) }
  }
  # 夹进虚拟桌面：拖出屏幕边会让右下角够不着，之后就再也拉不回来。
  $vs = [Windows.Forms.SystemInformation]::VirtualScreen
  $w = [Math]::Min($w, $vs.Width); $h = [Math]::Min($h, $vs.Height)
  if ($l -lt $vs.Left) { $l = $vs.Left }
  if ($t -lt $vs.Top) { $t = $vs.Top }
  if (($l + $w) -gt $vs.Right) { $l = $vs.Right - $w }
  if (($t + $h) -gt $vs.Bottom) { $t = $vs.Bottom - $h }
  $form.SetBounds($l, $t, $w, $h)
}

function End-Drag {
  if ($null -eq $script:DragOp) { return }
  $moved = ($script:DragOp.Mode -eq 'move' -or $script:DragOp.Zone -ne '')
  $script:DragOp = $null
  if ($moved) { Save-Geometry }
}

function Attach-Drag {
  param([Windows.Forms.Control]$Control, [bool]$Movable)
  $script:Movable[$Control] = $Movable
  $Control.Add_MouseDown({
      param($s, $e)
      if ($e.Button -ne 'Left') { return }
      $sp = $s.PointToScreen($e.Location)
      $z = Get-Zone $sp
      if ($z -ne '') {
        $script:DragOp = @{ Mode = 'size'; Zone = $z; StartPt = $sp; Bounds = $form.Bounds }
        $s.Capture = $true
      } elseif ($script:Movable[$s]) {
        $script:DragOp = @{ Mode = 'move'; Zone = ''; StartPt = $sp; Bounds = $form.Bounds }
        $s.Capture = $true
      }
    })
  $Control.Add_MouseMove({
      param($s, $e)
      $sp = $s.PointToScreen($e.Location)
      if ($null -eq $script:DragOp) {
        $s.Cursor = Zone-Cursor (Get-Zone $sp) ([bool]$script:Movable[$s])
        return
      }
      Update-Drag $sp
    })
  $Control.Add_MouseUp({
      param($s, $e)
      $s.Capture = $false
      End-Drag
      $s.Cursor = [Windows.Forms.Cursors]::Default
    })
}

# 可拖（移动）：标题栏整体、消息区（只读，拖它不损失什么）、进度轨、状态行。
foreach ($c in @($header, $lblTitle, $lblDot, $view, $hLine, $wsBar, $wsLine, $footLine)) { Attach-Drag $c $true }
# 只允许边缘缩放：输入框、按钮、窗体本身（窗体本体被上面的控件盖住，留着兜底）。
foreach ($c in @($form, $inputWrap, $inputFrame, $btnAsk, $btnLook, $btnHide, $btnClose, $cmbWs, $btnNew)) { Attach-Drag $c $false }
$btnNew.Add_Click({ New-Session })

# ── 提问 ─────────────────────────────────────────────────────────────────────
function Write-CardLog {
  param([string]$Text)
  try {
    $dir = Join-Path $env:USERPROFILE '.dsh\pet-chat'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $Text
    Add-Content -LiteralPath (Join-Path $dir 'card.log') -Value $line -Encoding UTF8
  } catch { }
}

function Set-Status {
  param([ValidateSet('idle', 'ok', 'busy', 'bad')][string]$Kind, [string]$Text)
  $script:StatusKind = $Kind
  $script:StatusText = $Text
  $map = @{ idle = $cMuted; ok = $cOk; busy = $cBusy; bad = $cBad }
  $lblDot.ForeColor = $map[$Kind]
  $lblHint.Text = $Text
  if ($Kind -eq 'bad') { Add-Notice $Text; $lblHint.ForeColor = $cBad }
  elseif ($Kind -eq 'busy') { $lblHint.ForeColor = $cBusy }
  else { $lblHint.ForeColor = $cMuted }
}

# 有字就收起占位；状态行只在没字且空闲时给一句键位提示，别和状态抢位置。
function Update-Hint {
  try { $lblPlaceholder.Visible = ($txtInput.TextLength -eq 0) } catch { }
  if ($script:StatusKind -eq 'busy' -or $script:StatusKind -eq 'bad') { return }
  if ($txtInput.Text.Trim() -eq '') {
    $lblHint.Text = ''
  } else {
    $lblHint.Text = 'Enter 发送'
    $lblHint.ForeColor = $cMuted
  }
}
$txtInput.Add_TextChanged({ try { Update-Hint } catch { } })

function Send-Question {
  param([bool]$WithShot, [string]$Override = $null)
  $question = ''
  if (-not [string]::IsNullOrWhiteSpace($Override)) { $question = $Override.Trim() } else { $question = $txtInput.Text.Trim() }
  Write-CardLog ('send: withShot=' + $WithShot + ' q=[' + $question + '] session=[' + $script:SessionId + ']')
  if (-not $WithShot -and $question -eq '') { Write-CardLog 'send: EMPTY QUESTION -> return'; return }

  if (-not $script:Base) {
    if (-not (Read-Endpoint)) {
      Set-Status 'bad' '未连接 dsh（缺 endpoint.json，重启 dsh）'
      return
    }
  }

  $body = @{ question = $question; sessionId = $script:SessionId }
  if ($WithShot) {
    Set-Status 'busy' '抓屏中…'
    $form.Refresh()
    try { $body.shot = Get-ShotBase64 }
    catch {
      Set-Status 'bad' "抓屏失败：$($_.Exception.Message)"
      return
    }
  }

  if ($question) { Add-Bubble $question ((Now-Meta) + ' · 你') 'mine' }
  else { Add-Bubble '（只发了一帧屏幕）' ((Now-Meta) + ' · 你') 'mine' }
  $script:Pending = $question
  Set-Status 'busy' '已送达，等待回答…'
  $txtInput.Clear()

  $res = Invoke-Api 'POST' '/api/pet-chat/ask' $body
  if ($null -eq $res) {
    Set-Status 'bad' '发送失败：宿主无响应（dsh 还在跑吗？）'
    return
  }
  if (-not $res.ok) {
    $reason = "发送失败：$($res.error)"
    if ($res.error -eq 'no-live-session') { $reason = '没有活会话：先在 dsh 里打开一个会话' }
    if ($res.error -eq 'unauthorized') { $reason = 'token 不匹配：重启 dsh 刷新 endpoint.json' }
    Set-Status 'bad' $reason
    return
  }
  if (-not $script:SessionId) { $script:SessionId = [string]$res.sessionId }
  if ($res.withShot) { Set-Status 'ok' '已带上屏幕，思考中…' } else { Set-Status 'ok' '已送达，思考中…' }
  $txtInput.Focus() | Out-Null
}

# 图标按钮与 Enter 同义：只发问题（不抓屏）；抓屏是左边的 ghost 按钮。
$btnAsk.Add_Click({
    try { Send-Question -WithShot $false }
    catch { Write-CardLog ('icon-click error: ' + $_.Exception.Message) ; Set-Status 'bad' ('发送出错：' + $_.Exception.Message) }
  })
$btnLook.Add_Click({
    try { Send-Question -WithShot $true }
    catch { Write-CardLog ('shot-click error: ' + $_.Exception.Message) ; Set-Status 'bad' ('发送出错：' + $_.Exception.Message) }
  })
$txtInput.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Enter' -and -not $e.Shift) {
      $e.SuppressKeyPress = $true
      try { Send-Question -WithShot $false }
      catch { Write-CardLog ('enter error: ' + $_.Exception.Message) ; Set-Status 'bad' ('发送出错：' + $_.Exception.Message) }
    }
  })
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Escape') { Hide-Card }
  })

# ── 工作区与新建会话 ─────────────────────────────────────────────────────────
$script:WsIds = @()

function Load-Workspaces {
  if (-not $script:Base) { return }
  $path = '/api/pet-chat/workspaces'
  if ($script:SessionId) { $path = $path + '?sessionId=' + [Uri]::EscapeDataString($script:SessionId) }
  $res = Invoke-Api 'GET' $path $null
  if ($null -eq $res -or -not $res.ok) { return }
  $list = @($res.workspaces)
  $script:WsIds = @($list | ForEach-Object { [string]$_.id })
  $cmbWs.BeginUpdate()
  $cmbWs.Items.Clear()
  foreach ($item in $list) { [void]$cmbWs.Items.Add([string]$item.title) }
  $cmbWs.EndUpdate()
  $cmbWs.Enabled = ($script:WsIds.Count -gt 0)
  $wanted = [string]$res.workspaceId
  $idx = 0
  if ($wanted) {
    $hit = [Array]::IndexOf($script:WsIds, $wanted)
    if ($hit -ge 0) { $idx = $hit }
  }
  if ($cmbWs.Items.Count -gt 0) { $cmbWs.SelectedIndex = $idx }
}

function New-Session {
  if (-not $script:Base) { Set-Status 'bad' '未连接 dsh（缺 endpoint.json）'; return }
  $ws = ''
  if ($cmbWs.SelectedIndex -ge 0 -and $cmbWs.SelectedIndex -lt $script:WsIds.Count) {
    $ws = [string]$script:WsIds[$cmbWs.SelectedIndex]
  }
  $res = Invoke-Api 'POST' '/api/pet-chat/session' @{ workspaceId = $ws }
  if ($null -eq $res -or -not $res.ok) {
    $why = '未知错误'
    if ($null -ne $res -and $res.error) { $why = [string]$res.error }
    Set-Status 'bad' ("新建会话失败：" + $why)
    return
  }
  $script:SessionId = [string]$res.sessionId
  $script:LastText = ''
  $script:Pending = $null
  $script:Msgs.Clear()
  $script:FreshSession = $true
  $lblTitle.Text = '新会话'
  Show-EmptyState
  Set-Status 'ok' '已新建会话'
  Refresh-State
}

# ── 轮询 ─────────────────────────────────────────────────────────────────────
function Refresh-State {
  if (-not $script:Base) {
    if (Read-Endpoint) { Set-Status 'ok' '已连接 dsh' } else { Set-Status 'bad' '未连接 dsh' }
    return
  }
  $path = '/api/pet-chat/state'
  if ($script:SessionId) { $path = $path + '?sessionId=' + [Uri]::EscapeDataString($script:SessionId) }
  $state = Invoke-Api 'GET' $path $null
  if ($null -eq $state -or -not $state.ok) {
    Set-Status 'bad' '未连接（endpoint.json 可能已过期，重启 dsh）'
    return
  }

  if (-not $script:SessionId -and $state.sessionId) { $script:SessionId = [string]$state.sessionId }
  $title = [string]$state.title
  # 新会话在 dsh 侧会先拿到一个 8 位短 id 当标题——用户看不懂，统一显示成「新会话」。
  if ($title -match '^[0-9a-f]{8}$') { $title = '' }
  if ($title) {
    $lblTitle.Text = $title
    $script:FreshSession = $false
  } elseif ($script:FreshSession) {
    $lblTitle.Text = '新会话'
  } else {
    $lblTitle.Text = '鲸鱼娘'
  }

  if ($state.running) {
    if ($script:LastStatus -ne 'running') { Set-Status 'busy' '思考中…' }
    $script:LastStatus = 'running'
  } else {
    if ($script:LastStatus -eq 'running') { Set-Status 'ok' '已回答' }
    $script:LastStatus = 'idle'
  }

  # 开机第一次拿到状态：有历史回答就直接显示它，没有才给空态教学文案。
  if ($script:BootIdle -and -not $state.text) { Show-EmptyState }
  if ($state.text -and $state.text -ne $script:LastText) {
    $script:LastText = [string]$state.text
    if ($null -ne $script:Pending) {
      Add-Bubble $script:LastText ((Now-Meta) + ' · 鲸鱼娘') 'theirs'
      $script:Pending = $null
    } elseif ($script:BootIdle) {
      # 开机就有历史回答：直接给它，别再叠一段空态教学文案（两段字挤在一起最像"糊"）。
      Add-Bubble $script:LastText ('最近回答 · ' + (Now-Meta)) 'theirs'
    } else {
      Add-Bubble $script:LastText ((Now-Meta) + ' · 鲸鱼娘') 'theirs'
    }
  }
  $script:BootIdle = $false
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({ try { Refresh-State } catch { } })

# ── 点官方桌宠 → 弹卡 ────────────────────────────────────────────────────────
# 宠物窗含透明留白：只取中段偏下的一块当热点，避免点在透明处也触发。
function Get-PetHotRect {
  $pet = [PetWin]::FindPet()
  if ($pet -eq [IntPtr]::Zero) { return $null }
  $r = New-Object PetWin+RECT
  if (-not [PetWin]::GetWindowRect($pet, [ref]$r)) { return $null }
  $w = $r.Right - $r.Left
  $h = $r.Bottom - $r.Top
  if ($w -le 0 -or $h -le 0) { return $null }
  $hotW = [int]($w * 0.62)
  $hotH = [int]($h * 0.82)
  return @{
    Left   = $r.Left + [int](($w - $hotW) / 2)
    Top    = $r.Bottom - $hotH
    Right  = $r.Left + [int](($w - $hotW) / 2) + $hotW
    Bottom = $r.Bottom
  }
}

$watcher = New-Object Windows.Forms.Timer
$watcher.Interval = 50
$watcher.Add_Tick({
    try {
      $down = ([PetWin]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
      $pos = [Windows.Forms.Cursor]::Position

      if ($down) {
        if ($null -eq $script:DownPoint) {
          $script:DownPoint = @{ X = $pos.X; Y = $pos.Y }
          Trace "down $($pos.X),$($pos.Y)"
        }
        return
      }
      if ($null -eq $script:DownPoint) { return }

      $start = $script:DownPoint
      $script:DownPoint = $null
      $moved = [Math]::Abs($pos.X - $start.X) + [Math]::Abs($pos.Y - $start.Y)
      Trace "up $($pos.X),$($pos.Y) moved=$moved"
      if ($moved -gt 8) { Trace 'skip: drag'; return }

      $hot = Get-PetHotRect
      if ($null -eq $hot) { Trace 'skip: pet-not-found'; return }
      if ($pos.X -lt $hot.Left -or $pos.X -gt $hot.Right -or $pos.Y -lt $hot.Top -or $pos.Y -gt $hot.Bottom) {
        Trace 'skip: outside-hot'; return
      }

      if ($script:CardOpen) { Hide-Card; Trace 'hidden' } else { Show-Card; Trace 'shown' }
    } catch { Trace ('error: ' + $_.Exception.Message) }
  })

# ── 托盘（卡片藏起来后仍可召回/退出）──────────────────────────────────────────
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('显示聊天卡')
$menu.Items[0].Add_Click({ Show-Card })
[void]$menu.Items.Add('退出')
$menu.Items[1].Add_Click({ $script:Tray.Visible = $false; [Windows.Forms.Application]::Exit() })

$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:Tray.Icon = [Drawing.SystemIcons]::Application
$script:Tray.Text = '鲸鱼娘 · 点桌宠提问'
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Visible = $true
$script:Tray.Add_MouseDoubleClick({ Show-Card })

# ── 生命周期 ─────────────────────────────────────────────────────────────────
# 白卡压在白窗口上会"飘"，描一圈淡蓝细边把它钉住。
$form.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $r = New-Object Drawing.Rectangle(0, 0, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 1))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = S 12
    $path.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $path.AddArc(($r.Right - $d), $r.Y, $d, $d, 270, 90)
    $path.AddArc(($r.Right - $d), ($r.Bottom - $d), $d, $d, 0, 90)
    $path.AddArc($r.X, ($r.Bottom - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    $pen = New-Object Drawing.Pen($cEdge, 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
  })
$form.Add_Resize({ try { Layout } catch { } })
$form.Add_ResizeEnd({ Save-Geometry })
$form.Add_FormClosing({ Save-Geometry })

# 不再挂 ResizeHook：子控件吃掉鼠标，系统 hit-test 到不了窗体边框（那正是"只能调宽度"的
# 根因）。移动/缩放全由上面 Attach-Drag 的 mouse 处理接管；ResizeHook 类留着但不用。
$form.Add_Shown({
    $script:K = $form.CreateGraphics().DpiX / 96.0
    # 句柄此时才存在，消息视图要按真实 DPI 配一次。
    Sync-View
    Layout
  })

$ctx = New-Object Windows.Forms.ApplicationContext
[Windows.Forms.Application]::add_ApplicationExit({ try { Save-Geometry; $script:Tray.Visible = $false } catch { } })

if ($Demo) {
  # 截图专用：不连宿主、不写会话，只把设计稿里的样例问答灌进视图，用来验排版。
  $script:Msgs.Clear()
  # 工作区条也要有内容，否则截图里是个空框，看不出长什么样。
  $script:WsIds = @('demo-ws-1', 'demo-ws-2')
  $cmbWs.Items.Clear()
  [void]$cmbWs.Items.Add('战斗系统')
  [void]$cmbWs.Items.Add('Agent初学起步')
  $cmbWs.SelectedIndex = 0
  Add-Bubble '这个 loss 曲线为什么会先降后升？是我 batch size 太小吗？' ((Now-Meta) + ' · 你') 'mine'
  Add-Bubble ("先给结论：后升的大概率不是 batch size，而是学习率没有随 warmup 结束回落。三个可以查的证据：`n" +
    "· 你的曲线在第 6 个 epoch 抬升，正好是 warmup 结束的位置`n" +
    "· 抬升前 loss 抖动幅度变大，符合 lr 偏高的典型特征`n" +
    "· 验证集 loss 同步抬头，说明不是过拟合`n" +
    "下一步：把 warmup_steps 从 500 调到 1500，或直接把峰值学习率降到 3e-4 再跑一次对照。") `
    ('最近回答 · ' + (Now-Meta)) 'theirs'
  # 再来两轮，让内容超过一屏：这样演示截图里能同时看到进度轨与滚动手感。
  Add-Bubble '那我先把 warmup_steps 调到 1500，再对比一次 loss 曲线？' ((Now-Meta) + ' · 你') 'mine'
  Add-Bubble ("可以。改完先只跑 200 步看前段：warmup 结束点应该在 1500 步而不是 500 步，抬升应该消失。`n" +
    "如果抬升还在，把峰值 lr 再降一档（3e-4 → 2e-4），同时把 batch size 提回 64 看抖动是否收敛。") `
    ('最近回答 · ' + (Now-Meta)) 'theirs'
  Add-Bubble '还有别的可能吗？' ((Now-Meta) + ' · 你') 'mine'
  Add-Bubble ("有：dataloader 的 shuffle 在 warmup 结束时才开始生效、或 schedule 写成了按 step 而不是按 epoch 重置。" +
    "这两种都能造成同样形状的抬升，日志里对一下 lr 的实际取值即可排除。") `
    ('最近回答 · ' + (Now-Meta)) 'theirs'
  Set-Status 'ok' '演示模式（不连宿主）'
} else {
  if (Read-Endpoint) { Refresh-State; Load-Workspaces } else { Show-EmptyState; Set-Status 'bad' '未连接 dsh（缺 endpoint.json）' }
}
# 窗体的 Add_Shown 只在首次显示后触发，本脚本平时不显示窗体 → 展开必须在这里主动做。
if ($Show) { Show-Card }
# -Demo 不轮询：轮询会用真实会话内容覆盖样例问答。
if (-not $Demo) { $timer.Start() }
$watcher.Start()

[Windows.Forms.Application]::Run($ctx)
