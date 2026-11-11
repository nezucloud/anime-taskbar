# Plays mood-based sprite animations on the taskbar, in the gap between the Widgets (weather) button and Start.
# The mood follows system load: calm -> busy -> exhausted as CPU or RAM usage climbs.
# Uses per-pixel alpha so soft glows blend with the taskbar. The overlay is click-through, follows Start
# as it moves, and hides during fullscreen apps. Hover the tray icon for CPU/RAM; right-click -> Exit.
# Sprites: <stem>.json lists the moods; each mood is a vertical sprite sheet <stem>_<mood>.png (see make_moods.py).
param(
    [string]$SpriteStem = (Join-Path $PSScriptRoot 'heads'),
    [ValidateSet('auto', 'calm', 'busy', 'exhausted')]
    [string]$Mood = 'auto'      # pin a mood instead of following system load (handy for previewing)
)

$singleInstance = New-Object System.Threading.Mutex($false, 'Local\TaskbarMoodOverlay')
if (-not $singleInstance.WaitOne(0)) { exit }   # already running

Add-Type -AssemblyName System, System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes, WindowsBase

$referencedAssemblies = 'System', 'System.Windows.Forms', 'System.Drawing', 'UIAutomationClient', 'UIAutomationTypes', 'WindowsBase' |
    ForEach-Object { [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location -Like "*\$_.dll" | Select-Object -First 1 -ExpandProperty Location }

Add-Type -ReferencedAssemblies $referencedAssemblies -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Forms;

// Locates the empty stretch of taskbar between the Widgets button and the Start button.
public class TaskbarGap
{
    AutomationElement widgetsButton, startButton;

    public bool TryGetBounds(out Rectangle gap)
    {
        gap = Rectangle.Empty;
        try
        {
            if (startButton == null || widgetsButton == null) FindButtons();
            System.Windows.Rect widgets = widgetsButton.Current.BoundingRectangle;
            System.Windows.Rect start = startButton.Current.BoundingRectangle;
            gap = Rectangle.FromLTRB((int)widgets.Right, (int)start.Top, (int)start.Left, (int)start.Bottom);
            return gap.Width > 0 && gap.Height > 0;
        }
        catch (Exception)   // Explorer restarted or the taskbar is mid-rebuild; look again next time.
        {
            widgetsButton = startButton = null;
            return false;
        }
    }

    void FindButtons()
    {
        AutomationElement taskbar = AutomationElement.RootElement.FindFirst(TreeScope.Children,
            new PropertyCondition(AutomationElement.ClassNameProperty, "Shell_TrayWnd"));
        widgetsButton = FindById(taskbar, "WidgetsButton");
        startButton = FindById(taskbar, "StartButton");
    }

    static AutomationElement FindById(AutomationElement parent, string automationId)
    {
        AutomationElement found = parent.FindFirst(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.AutomationIdProperty, automationId));
        if (found == null) throw new InvalidOperationException(automationId + " not found");
        return found;
    }
}

// Frames cut from a vertical sprite sheet, held as GDI bitmaps ready for UpdateLayeredWindow.
public sealed class SpriteFrames : IDisposable
{
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);

    public readonly IntPtr[] Bitmaps;
    public readonly Size FrameSize;

    public SpriteFrames(string sheetPath, int frameWidth, int frameHeight, int frameCount)
    {
        FrameSize = new Size(frameWidth, frameHeight);
        Bitmaps = new IntPtr[frameCount];
        using (var sheet = new Bitmap(new MemoryStream(File.ReadAllBytes(sheetPath))))
        {
            for (int i = 0; i < frameCount; i++)
            {
                var area = new Rectangle(0, i * frameHeight, frameWidth, frameHeight);
                using (Bitmap frame = sheet.Clone(area, PixelFormat.Format32bppArgb))
                    Bitmaps[i] = frame.GetHbitmap(Color.FromArgb(0));   // premultiplied, keeps alpha
            }
        }
    }

    public void Dispose()
    {
        foreach (IntPtr bitmap in Bitmaps) DeleteObject(bitmap);
    }
}

// Smoothed CPU and RAM usage, graded into mood levels: 0 calm, 1 busy, 2 exhausted.
public sealed class LoadMonitor : IDisposable
{
    const double CPU_BUSY = 40, CPU_EXHAUSTED = 75, RAM_BUSY = 70, RAM_EXHAUSTED = 88;
    const double SMOOTHING = 0.4;      // weight of the newest CPU sample

    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX
    {
        public uint Length, MemoryLoad;
        public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
    }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);

    readonly PerformanceCounter cpuCounter = CreateCpuCounter();
    bool sampled;

    public double Cpu { get; private set; }
    public double Ram { get; private set; }
    public int Level { get { return Math.Max(Grade(Cpu, CPU_BUSY, CPU_EXHAUSTED), Grade(Ram, RAM_BUSY, RAM_EXHAUSTED)); } }

    public void Sample()
    {
        double cpuNow = Math.Min(100, cpuCounter.NextValue());
        Cpu = sampled ? Cpu * (1 - SMOOTHING) + cpuNow * SMOOTHING : cpuNow;
        Ram = MemoryLoad();
        sampled = true;
    }

    static PerformanceCounter CreateCpuCounter()
    {
        try
        {
            var utility = new PerformanceCounter("Processor Information", "% Processor Utility", "_Total");   // matches Task Manager
            utility.NextValue();
            return utility;
        }
        catch (Exception)
        {
            return new PerformanceCounter("Processor", "% Processor Time", "_Total");
        }
    }

    static double MemoryLoad()
    {
        var status = new MEMORYSTATUSEX { Length = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) };
        return GlobalMemoryStatusEx(ref status) ? status.MemoryLoad : 0;
    }

    static int Grade(double value, double busy, double exhausted)
    {
        return value >= exhausted ? 2 : value >= busy ? 1 : 0;
    }

    public void Dispose() { cpuCounter.Dispose(); }
}

public class TaskbarMoodOverlay : Form
{
    const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;
    const int ULW_ALPHA = 0x2;
    const byte AC_SRC_OVER = 0, AC_SRC_ALPHA = 1;
    const int QUNS_BUSY = 2, QUNS_RUNNING_D3D_FULL_SCREEN = 3, QUNS_PRESENTATION_MODE = 4;
    const int RAISE_EVERY_MS = 250, REPOSITION_EVERY_MS = 2000, SAMPLE_EVERY_MS = 1000;
    const int SAMPLES_BEFORE_MOOD_CHANGE = 3;      // load must stay at a new level ~3 s before the mood follows
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int Cx, Cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hWnd, IntPtr hdcDst, ref POINT dst, ref SIZE size,
        IntPtr hdcSrc, ref POINT src, int colorKey, ref BLENDFUNCTION blend, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);

    readonly NotifyIcon tray;
    readonly TaskbarGap gap = new TaskbarGap();
    readonly LoadMonitor load = new LoadMonitor();
    readonly SpriteFrames[] moods;
    readonly string[] moodNames;
    readonly int pinnedMood;                       // -1 = follow system load
    readonly Timer timer;
    readonly int raiseEveryTicks, repositionEveryTicks, sampleEveryTicks;
    Rectangle placement;
    int ticks, frame, currentMood, wantedMood, candidateMood, candidateSamples;

    public TaskbarMoodOverlay(SpriteFrames[] moods, string[] moodNames, int frameMs, int pinnedMood)
    {
        this.moods = moods;
        this.moodNames = moodNames;
        this.pinnedMood = pinnedMood;
        currentMood = wantedMood = candidateMood = Math.Max(0, pinnedMood);
        timer = new Timer { Interval = frameMs };
        raiseEveryTicks = Math.Max(1, RAISE_EVERY_MS / frameMs);
        repositionEveryTicks = Math.Max(1, REPOSITION_EVERY_MS / frameMs);
        sampleEveryTicks = Math.Max(1, SAMPLE_EVERY_MS / frameMs);

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Size = moods[0].FrameSize;
        tray = CreateTrayIcon();
        timer.Tick += (s, e) => OnTick();
    }

    NotifyIcon CreateTrayIcon()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Exit", null, (s, e) => Close());
        return new NotifyIcon { Icon = SystemIcons.Application, Text = "taskbar overlay", ContextMenuStrip = menu, Visible = true };
    }

    void OnTick()
    {
        if (ticks % sampleEveryTicks == 0) SampleLoad();
        if (FullscreenAppRunning()) { Hide(); ticks++; return; }
        if (ticks % repositionEveryTicks == 0) FitIntoGap();
        if (!Visible) Show();
        if (ticks % raiseEveryTicks == 0) RaiseAboveTaskbar();
        AdvanceFrame();
        ticks++;
    }

    void SampleLoad()
    {
        load.Sample();
        if (pinnedMood < 0) TrackMood(Math.Min(load.Level, moods.Length - 1));
        tray.Text = string.Format("CPU {0:0}%  RAM {1:0}%  - {2}", load.Cpu, load.Ram, moodNames[wantedMood]);
    }

    void TrackMood(int level)
    {
        if (level != candidateMood) { candidateMood = level; candidateSamples = 0; }
        if (++candidateSamples >= SAMPLES_BEFORE_MOOD_CHANGE) wantedMood = candidateMood;
    }

    void AdvanceFrame()
    {
        if (frame == 0) currentMood = wantedMood;  // every mood loops back to the same pose at frame 0
        DrawFrame(moods[currentMood].Bitmaps[frame]);
        frame = (frame + 1) % moods[currentMood].Bitmaps.Length;
    }

    void FitIntoGap()
    {
        Rectangle bounds;
        if (!gap.TryGetBounds(out bounds)) return;
        Size frameSize = moods[0].FrameSize;
        int width = Math.Min(frameSize.Width, bounds.Width);
        int height = Math.Min(frameSize.Height, bounds.Height);
        placement = new Rectangle(bounds.X + (bounds.Width - width) / 2, bounds.Y + (bounds.Height - height) / 2, width, height);
    }

    void DrawFrame(IntPtr bitmap)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memoryDc = CreateCompatibleDC(screenDc);
        IntPtr previous = SelectObject(memoryDc, bitmap);
        try
        {
            var dst = new POINT { X = placement.X, Y = placement.Y };
            var size = new SIZE { Cx = placement.Width, Cy = placement.Height };
            var src = new POINT { X = (moods[0].FrameSize.Width - placement.Width) / 2, Y = 0 };
            var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memoryDc, ref src, 0, ref blend, ULW_ALPHA);
        }
        finally
        {
            SelectObject(memoryDc, previous);
            DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    void RaiseAboveTaskbar()
    {
        SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    static bool FullscreenAppRunning()
    {
        int state;
        if (SHQueryUserNotificationState(out state) != 0) return false;
        return state == QUNS_BUSY || state == QUNS_RUNNING_D3D_FULL_SCREEN || state == QUNS_PRESENTATION_MODE;
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        FitIntoGap();
        RaiseAboveTaskbar();
        timer.Start();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            timer.Dispose();
            tray.Dispose();
            load.Dispose();
            foreach (SpriteFrames sprites in moods) sprites.Dispose();
        }
        base.Dispose(disposing);
    }
}
'@


function Import-MoodSprites([string]$Stem) {
    $meta = Get-Content "$Stem.json" -Raw | ConvertFrom-Json
    $sprites = foreach ($name in $meta.moods) {
        New-Object SpriteFrames -ArgumentList "$($Stem)_$name.png", $meta.frameWidth, $meta.frameHeight, $meta.frameCount
    }
    [pscustomobject]@{ Names = [string[]]$meta.moods; Sprites = [SpriteFrames[]]$sprites; FrameMs = [int]$meta.frameMs }
}

$sprites = Import-MoodSprites (Resolve-Path "$SpriteStem.json").Path.Replace('.json', '')
$pinned = if ($Mood -eq 'auto') { -1 } else { [array]::IndexOf($sprites.Names, $Mood) }
$overlay = New-Object TaskbarMoodOverlay -ArgumentList $sprites.Sprites, $sprites.Names, $sprites.FrameMs, $pinned
[System.Windows.Forms.Application]::Run($overlay)
