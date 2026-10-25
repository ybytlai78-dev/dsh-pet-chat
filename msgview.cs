// 消息视图：自绘（GDI+ 手动折行），换来设计稿要求的精确行高与真圆角气泡。
// 为什么不用 RichTextBox：它的行距由字体度量决定（约 1.35 倍），设计稿要 1.6 倍；
// 14px 正文跑 14 行就累积 98px 偏差，底栏会被顶出卡片。这里自己量、自己画。
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class PetMsgView : Control
{
    public class Msg
    {
        public string Kind;   // mine | theirs | empty | error | meta 里的 meta 走 Msg.Meta
        public string Text;
        public string Meta;
        public Msg() { }
        public Msg(string kind, string text, string meta) { Kind = kind; Text = text; Meta = meta; }
    }

    readonly List<Msg> items = new List<Msg>();
    readonly List<object[]> blocks = new List<object[]>();

    float k = 1f;
    int LineH = 22;
    int MetaLineH = 17;
    int PadL = 16, PadR = 20, PadT = 14, PadB = 16;
    public Color CText = Color.FromArgb(28, 40, 58);
    public Color CMuted = Color.FromArgb(94, 112, 137);
    public Color CBubble = Color.FromArgb(232, 240, 254);
    public Color CBubbleInk = Color.FromArgb(23, 53, 111);
    public Color CTrack = Color.FromArgb(228, 237, 250);
    public Color CThumb = Color.FromArgb(157, 190, 240);
    public Color CBadBg = Color.FromArgb(253, 241, 238);
    public Color CBadLine = Color.FromArgb(239, 211, 203);
    public Color CBadInk = Color.FromArgb(168, 64, 44);
    Font fBody, fMeta;

    int scrollY;
    int contentH;
    int lastW = -1;
    // 上次排版的宽度：OnPaint 里发现宽度变了就重排（Size 事件时序不可靠）

    public PetMsgView()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
               | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, true);   // 要能接键盘（PageUp/PageDown/Home/End）
        TabStop = false;
        DoubleBuffered = true;
        BackColor = Color.White;
    }

    public void Configure(float dpiScale, Font body, Font meta)
    {
        k = dpiScale;
        fBody = body;
        fMeta = meta;
        LineH = (int)Math.Round(22 * k);
        MetaLineH = (int)Math.Round(17 * k);
        PadL = (int)Math.Round(16 * k);
        PadR = (int)Math.Round(20 * k);
        PadT = (int)Math.Round(14 * k);
        PadB = (int)Math.Round(16 * k);
        Rebuild();
    }

    public void Reset(Msg[] next)
    {
        items.Clear();
        if (next != null) items.AddRange(next);
        Rebuild();
        ScrollToEnd();
    }

    public void Append(Msg m)
    {
        items.Add(m);
        Rebuild();
        ScrollToEnd();
    }

    public void ScrollToEnd()
    {
        scrollY = Math.Max(0, contentH - ClientSize.Height);
        Invalidate();
    }

    // 折行：CJK 逐字、拉丁按词；每加一片就整行重量一次（逐片累加会有舍入漂移，
    // 30 个字下来能差出 30px，行尾就会莫名提前断行）。
    string[] Wrap(string text, Font font, int maxW)
    {
        var lines = new List<string>();
        if (text == null) text = "";
        var cache = new Dictionary<string, int>();
        Func<string, int> width = delegate(string str)
        {
            int w;
            if (!cache.TryGetValue(str, out w))
            {
                w = TextRenderer.MeasureText(str, font, new Size(short.MaxValue, short.MaxValue),
                        TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width;
                cache[str] = w;
            }
            return w;
        };

        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            if (raw.Length == 0) { lines.Add(""); continue; }
            var line = new System.Text.StringBuilder();
            int i = 0;
            while (i < raw.Length)
            {
                int len = 1;
                char ch = raw[i];
                if (ch == ' ')
                {
                    while (i + len < raw.Length && raw[i + len] == ' ') len++;
                }
                else if (ch < 128)
                {
                    while (i + len < raw.Length && raw[i + len] < 128 && raw[i + len] != ' ') len++;
                }

                string tok = raw.Substring(i, len);
                string cand = line.ToString() + tok;
                if (line.Length > 0 && width(cand) > maxW)
                {
                    lines.Add(line.ToString());
                    line.Length = 0;
                    if (tok == " ") { i += len; continue; }
                }
                line.Append(tok);
                i += len;
            }
            lines.Add(line.ToString());
        }
        return lines.ToArray();
    }

    int Measure(string s)
    {
        return TextRenderer.MeasureText(s, fBody, new Size(short.MaxValue, short.MaxValue),
                   TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width;
    }

    void Rebuild()
    {
        blocks.Clear();
        if (fBody == null) return;
        int y = PadT;
        int innerW = ClientSize.Width - PadL - PadR;
        if (innerW < 60) { contentH = 0; return; }

        foreach (var m in items)
        {
            int bodyMax = m.Kind == "mine"
                ? Math.Max((int)(innerW * 0.82) - (int)Math.Round(22 * k), 60)
                : innerW;
            var lines = Wrap(m.Text ?? "", fBody, bodyMax);

            if (m.Kind == "mine")
            {
                int widest = 0;
                foreach (var ln in lines) widest = Math.Max(widest, Measure(ln));
                int padX = (int)Math.Round(22 * k);
                int bw = Math.Min(widest + padX, bodyMax + padX);
                int bh = lines.Length * LineH + (int)Math.Round(14 * k);
                int bx = Math.Max(PadL, ClientSize.Width - PadR - bw);
                blocks.Add(new object[] { "mine", lines, bx, y, bw, bh });
                y += bh + (int)Math.Round(12 * k);
            }
            else if (m.Kind == "error")
            {
                int bh = lines.Length * LineH + (int)Math.Round(20 * k);
                blocks.Add(new object[] { "error", lines, PadL, y, innerW, bh });
                y += bh + (int)Math.Round(12 * k);
            }
            else
            {
                if (!String.IsNullOrEmpty(m.Meta))
                {
                    blocks.Add(new object[] { "meta", new string[] { m.Meta }, PadL, y, innerW, MetaLineH });
                    y += MetaLineH + (int)Math.Round(6 * k);
                }
                int bh = Math.Max(lines.Length * LineH, LineH);
                blocks.Add(new object[] { m.Kind == "empty" ? "empty" : "theirs", lines, PadL, y, innerW, bh });
                y += bh + (int)Math.Round(12 * k);
            }
        }

        lastW = ClientSize.Width;
        contentH = y + PadB;
        int maxScroll = Math.Max(0, contentH - ClientSize.Height);
        if (scrollY > maxScroll) scrollY = maxScroll;
        Invalidate();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Rebuild();
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        int maxScroll = Math.Max(0, contentH - ClientSize.Height);
        scrollY = Math.Max(0, Math.Min(scrollY - e.Delta, maxScroll));
        Invalidate();
    }

    int RailWidth() { return Math.Max(3, (int)Math.Round(3 * k)); }
    int RailTop() { return (int)Math.Round(10 * k); }
    int RailHeight() { return ClientSize.Height - (int)Math.Round(20 * k); }
    int ThumbHeight(int rh)
    {
        return Math.Max((int)Math.Round(24 * k), (int)(rh * (double)ClientSize.Height / contentH));
    }

    protected override bool IsInputKey(Keys keyData)
    {
        switch (keyData)
        {
            case Keys.PageUp:
            case Keys.PageDown:
            case Keys.Home:
            case Keys.End:
                return true;
        }
        return base.IsInputKey(keyData);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        int page = Math.Max(ClientSize.Height - LineH * 2, LineH);
        int maxScroll = Math.Max(0, contentH - ClientSize.Height);
        switch (e.KeyCode)
        {
            case Keys.PageDown: scrollY = Math.Min(scrollY + page, maxScroll); break;
            case Keys.PageUp: scrollY = Math.Max(scrollY - page, 0); break;
            case Keys.End: scrollY = maxScroll; break;
            case Keys.Home: scrollY = 0; break;
            default: return;
        }
        e.Handled = true;
        Invalidate();
    }

    // 诊断用：把排版结果说清楚（哪块、几行、每行多长），气泡画不出字时一眼看出问题在折行还是绘制。
    public string Dump()
    {
        var sb = new System.Text.StringBuilder();
        sb.Append("k=" + k + " W=" + ClientSize.Width + " blocks=" + blocks.Count);
        foreach (var b in blocks)
        {
            var lines = (string[])b[1];
            int chars = 0;
            foreach (var l in lines) chars += (l ?? "").Length;
            sb.Append(" | " + (string)b[0] + ":" + lines.Length + "行/" + chars + "字/" + (int)b[4] + "x" + (int)b[5]);
        }
        return sb.ToString();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (ClientSize.Width != lastW) Rebuild();   // 尺寸事件可能晚于首帧，这里兜底

        var g = e.Graphics;
        g.Clear(BackColor);

        // 注意：这里不能用 g.TranslateTransform 做滚动——TextRenderer 走 GDI，不认 GDI+ 的世界变换，
        // 结果是气泡（GDI+ 路径）被平移、文字却留在原地，一滚动就"气泡空着、字跑到别处"。
        // 所以每个块自己算 y - scrollY，两套绘制用同一套坐标。
        foreach (var b in blocks)
        {
            string kind = (string)b[0];
            var lines = (string[])b[1];
            int x = (int)b[2], y = (int)b[3] - scrollY, w = (int)b[4], h = (int)b[5];
            if (y > ClientSize.Height || y + h < 0) continue;

            if (kind == "mine" || kind == "error")
            {
                bool err = kind == "error";
                using (var path = Round(x, y, w, h, (int)Math.Round((err ? 8 : 10) * k)))
                {
                    using (var br = new SolidBrush(err ? CBadBg : CBubble)) g.FillPath(br, path);
                    if (err)
                    {
                        using (var pen = new Pen(CBadLine, Math.Max(k, 1f))) g.DrawPath(pen, path);
                    }
                }
                int ty = y + (int)Math.Round((err ? 10 : 7) * k);
                foreach (var ln in lines)
                {
                    if (ln.Length > 0)
                        TextRenderer.DrawText(g, ln, fBody, new Point(x + (int)Math.Round(11 * k), ty),
                            err ? CBadInk : CBubbleInk, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
                    ty += LineH;
                }
            }
            else if (kind == "meta")
            {
                TextRenderer.DrawText(g, lines[0], fMeta, new Point(x, y), CMuted,
                    TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            }
            else
            {
                Color c = kind == "empty" ? CMuted : CText;
                int ty = y;
                foreach (var ln in lines)
                {
                    if (ln.Length > 0)
                        TextRenderer.DrawText(g, ln, fBody, new Point(x, ty), c,
                            TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
                    ty += LineH;
                }
            }
        }

        // 右侧 3px 进度轨：可见部分 = 滑块，余下是轨道。
        if (contentH > ClientSize.Height)
        {
            int railW = RailWidth();
            int top = RailTop(), rh = RailHeight();
            if (rh > 8)
            {
                int rx = ClientSize.Width - (int)Math.Round(5 * k) - railW;
                using (var br = new SolidBrush(CTrack)) g.FillRectangle(br, rx, top, railW, rh);
                int th = ThumbHeight(rh);
                int maxScroll = contentH - ClientSize.Height;
                double ratio = maxScroll <= 0 ? 0 : (double)scrollY / maxScroll;
                int ty2 = top + (int)((rh - th) * ratio);
                using (var br2 = new SolidBrush(CThumb)) g.FillRectangle(br2, rx, ty2, railW, th);
            }
        }
    }

    static GraphicsPath Round(int x, int y, int w, int h, int r)
    {
        var p = new GraphicsPath();
        int d = r * 2;
        if (d <= 0 || w <= d || h <= d) { p.AddRectangle(new Rectangle(x, y, w, h)); return p; }
        p.AddArc(x, y, d, d, 180, 90);
        p.AddArc(x + w - d, y, d, d, 270, 90);
        p.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        p.AddArc(x, y + h - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
