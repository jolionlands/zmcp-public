param([string]$Dir = "K:\zmcp-live")
# Instrumented target window for the zmcp-computer live test. Logs every
# mouse/key message it receives (physical screen coordinates) to events.log.
$ErrorActionPreference = "Stop"
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class Dpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
}

public static class EvLog {
    public static StreamWriter W;
    public static void Line(string s) { lock (typeof(EvLog)) { W.WriteLine(s); } }
}

public class Pad : Control {
    public Pad() { SetStyle(ControlStyles.Selectable, true); TabStop = true; }
    protected override void OnMouseDown(MouseEventArgs e) { Focus(); base.OnMouseDown(e); }
    protected override void WndProc(ref Message m) {
        int msg = m.Msg;
        long lp = m.LParam.ToInt64();
        int x = (short)(lp & 0xFFFF); int y = (short)((lp >> 16) & 0xFFFF);
        if (msg >= 0x0201 && msg <= 0x0209) {
            Point s = PointToScreen(new Point(x, y));
            EvLog.Line("MOUSE " + msg.ToString("X4") + " " + s.X + " " + s.Y);
        } else if (msg == 0x0200) {
            Point s = PointToScreen(new Point(x, y));
            EvLog.Line("MOVE " + s.X + " " + s.Y);
        } else if (msg == 0x020A || msg == 0x020E) {
            int delta = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
            EvLog.Line("WHEEL " + msg.ToString("X4") + " " + delta + " " + x + " " + y);
            if (msg == 0x020E) { m.Result = (IntPtr)1; return; }
        }
        base.WndProc(ref m);
    }
}

public class Target : Form {
    public TextBox Box; public Label Probe; public Pad PadCtl;
    string dir;
    public Target(string d) {
        dir = d;
        Text = "zmcp-live-target";
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(120, 120);
        Size = new Size(900, 700);
        KeyPreview = true;
        Box = new TextBox(); Box.Multiline = true; Box.AcceptsTab = true; Box.AcceptsReturn = true;
        Box.Font = new Font("Segoe UI", 20); Box.Dock = DockStyle.Top; Box.Height = 190;
        Probe = new Label(); Probe.Text = "OCR PROBE 4217"; Probe.Font = new Font("Arial", 30, FontStyle.Bold);
        Probe.Dock = DockStyle.Top; Probe.Height = 70; Probe.BackColor = Color.White; Probe.ForeColor = Color.Black;
        PadCtl = new Pad(); PadCtl.Dock = DockStyle.Fill; PadCtl.BackColor = Color.LightSteelBlue;
        Controls.Add(PadCtl); Controls.Add(Probe); Controls.Add(Box);
        Box.TextChanged += (s, e) => EvLog.Line("TEXT " + Convert.ToBase64String(Encoding.UTF8.GetBytes(Box.Text)));
        KeyDown += (s, e) => EvLog.Line("KEY " + e.KeyCode + " " + e.Modifiers.ToString().Replace(", ", "|"));
        Shown += (s, e) => WriteReady();
        FormClosed += (s, e) => { EvLog.Line("CLOSED"); EvLog.W.Flush(); };
    }
    static string R(Rectangle r) { return "{\"x\":" + r.X + ",\"y\":" + r.Y + ",\"w\":" + r.Width + ",\"h\":" + r.Height + "}"; }
    void WriteReady() {
        Rectangle pad = PadCtl.RectangleToScreen(PadCtl.ClientRectangle);
        Rectangle box = Box.RectangleToScreen(Box.ClientRectangle);
        Rectangle probe = Probe.RectangleToScreen(Probe.ClientRectangle);
        string json = "{\"pad\":" + R(pad) + ",\"box\":" + R(box) + ",\"probe\":" + R(probe) + ",\"form\":" + R(Bounds) + ",\"hwnd\":" + Handle.ToInt64() + "}";
        File.WriteAllText(Path.Combine(dir, "ready.json"), json);
    }
}
"@
[Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$w = New-Object System.IO.StreamWriter((Join-Path $Dir "events.log"), $false, (New-Object System.Text.UTF8Encoding($false)))
$w.AutoFlush = $true
[EvLog]::W = $w
[System.Windows.Forms.Application]::EnableVisualStyles()
$f = New-Object Target($Dir)
[System.Windows.Forms.Application]::Run($f)
$w.Close()
