# Plays mood-based sprite animations on the taskbar, in the gap between the Widgets (weather) button and Start.
# The mood follows system load: calm -> busy -> exhausted as CPU or RAM usage climbs.
# Uses per-pixel alpha so soft glows blend with the taskbar. The overlay docks inside the taskbar window (so it
# stays visible while Start is open), is click-through, follows Start as it moves, and hides during fullscreen apps.
# Hover the tray icon for CPU/RAM; right-click -> Exit.
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
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Forms;

// Locates the empty stretch of taskbar between the Widgets button and the Start button.
// UI Automation gives the exact button bounds, but once Start has been opened Windows stops exposing the taskbar's
// insides to it. Then the task-icon strip (which begins at Start) and the last measured Widgets edge stand in.
public class TaskbarGap
{
    const int DEFAULT_WIDGETS_RIGHT = 54;          // Widgets button at the left end of a 48 px taskbar

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    AutomationElement widgetsButton, startButton;
    int widgetsRight = DEFAULT_WIDGETS_RIGHT;

    public bool TryGetBounds(out Rectangle gap)
    {
        gap = MeasureButtons();
        if (!IsUsable(gap)) gap = EstimateFromTaskIcons();
        return IsUsable(gap);
    }

    static bool IsUsable(Rectangle gap) { return gap.Width > 0 && gap.Height > 0; }

    Rectangle MeasureButtons()
    {
        try
        {
            if (startButton == null || widgetsButton == null) FindButtons();
            System.Windows.Rect widgets = widgetsButton.Current.BoundingRectangle;
            System.Windows.Rect start = startButton.Current.BoundingRectangle;
            if (widgets.IsEmpty || start.IsEmpty) return Forget();
            widgetsRight = (int)widgets.Right;
            return Rectangle.FromLTRB(widgetsRight, (int)start.Top, (int)start.Left, (int)start.Bottom);
        }
        catch (Exception)   // Explorer restarted, the taskbar is mid-rebuild, or it is hidden from UI Automation
        {
            return Forget();
        }
    }

    Rectangle Forget()
    {
        widgetsButton = startButton = null;
        return Rectangle.Empty;
    }

    Rectangle EstimateFromTaskIcons()
    {
        IntPtr taskIcons = FindWindowEx(FindWindow("Shell_TrayWnd", null), IntPtr.Zero, "ReBarWindow32", null);
        RECT strip;
        if (taskIcons == IntPtr.Zero || !GetWindowRect(taskIcons, out strip)) return Rectangle.Empty;
        return Rectangle.FromLTRB(widgetsRight, strip.Top, strip.Left, strip.Bottom);
    }

    void FindButtons()
    {
        AutomationElement taskbar = AutomationElement.FromHandle(FindWindow("Shell_TrayWnd", null));
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

// Turns load samples into the mood the heads should show, waiting ~3 s before following a change.
public sealed class MoodTracker : IDisposable
{
    const int SAMPLES_BEFORE_MOOD_CHANGE = 3;

    readonly LoadMonitor load = new LoadMonitor();
    readonly string[] moodNames;
    readonly int pinnedMood;                       // -1 = follow system load
    int candidateMood, candidateSamples;

    public MoodTracker(string[] moodNames, int pinnedMood)
    {
        this.moodNames = moodNames;
        this.pinnedMood = pinnedMood;
        Wanted = candidateMood = Math.Max(0, pinnedMood);
    }

    public int Wanted { get; private set; }

    public string Status
    {
        get { return string.Format("CPU {0:0}%  RAM {1:0}%  - {2}", load.Cpu, load.Ram, moodNames[Wanted]); }
    }

    public void Sample()
    {
        load.Sample();
        if (pinnedMood < 0) Follow(Math.Min(load.Level, moodNames.Length - 1));
    }

    void Follow(int level)
    {
        if (level != candidateMood) { candidateMood = level; candidateSamples = 0; }
        if (++candidateSamples >= SAMPLES_BEFORE_MOOD_CHANGE) Wanted = candidateMood;
    }

    public void Dispose() { load.Dispose(); }
}

// The animation, docked inside the taskbar window as a child. The first time Start or Search opens, Windows lifts
// the taskbar into a higher window band for good, above every ordinary always-on-top window, and it also stops
// accepting new child windows from other programs. So the overlay must dock while the taskbar is still in the
// desktop band (at sign-in, or right after Explorer restarts); once docked it travels with the taskbar.
public sealed class TaskbarMoodOverlay : NativeWindow, IDisposable
{
    const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
    const int WS_CHILD = 0x40000000, WS_CLIPSIBLINGS = 0x04000000;
    const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;
    const int ULW_ALPHA = 0x2;
    const byte AC_SRC_OVER = 0, AC_SRC_ALPHA = 1;
    const int QUNS_BUSY = 2, QUNS_RUNNING_D3D_FULL_SCREEN = 3, QUNS_PRESENTATION_MODE = 4;
    const int RAISE_EVERY_MS = 250, REPOSITION_EVERY_MS = 2000;
    static readonly IntPtr HWND_TOP = IntPtr.Zero;

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int Cx, Cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll")] static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hWnd, ref POINT point);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hWnd, IntPtr hdcDst, IntPtr keepPosition, ref SIZE size,
        IntPtr hdcSrc, ref POINT src, int colorKey, ref BLENDFUNCTION blend, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);

    readonly IntPtr taskbar;
    readonly TaskbarGap gap = new TaskbarGap();
    readonly SpriteFrames[] moods;
    readonly MoodTracker mood;
    readonly Timer timer;
    readonly int raiseEveryTicks, repositionEveryTicks;
    Rectangle placement;                           // in taskbar client coordinates
    int ticks, frame, currentMood;
    bool visible;

    public static IntPtr FindTaskbar() { return FindWindow("Shell_TrayWnd", null); }

    // A plain native window rather than a Form: WinForms would re-park a Form under its own hidden window.
    // Throws Win32Exception when the taskbar refuses the child window (it already moved to the higher band).
    public TaskbarMoodOverlay(SpriteFrames[] moods, int frameMs, MoodTracker mood, IntPtr taskbar)
    {
        this.moods = moods;
        this.mood = mood;
        this.taskbar = taskbar;
        currentMood = mood.Wanted;
        raiseEveryTicks = Math.Max(1, RAISE_EVERY_MS / frameMs);
        repositionEveryTicks = Math.Max(1, REPOSITION_EVERY_MS / frameMs);

        CreateHandle(DockedWindowParams());
        FitIntoGap();
        timer = new Timer { Interval = frameMs };
        timer.Tick += (s, e) => OnTick();
        timer.Start();
    }

    // False once Explorer restarts: the taskbar is destroyed and takes this docked window with it.
    public bool IsDocked { get { return Handle != IntPtr.Zero; } }

    CreateParams DockedWindowParams()
    {
        Size size = moods[0].FrameSize;
        return new CreateParams
        {
            Parent = taskbar,
            Style = WS_CHILD | WS_CLIPSIBLINGS,
            ExStyle = WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE,
            Width = size.Width,
            Height = size.Height,
        };
    }

    void OnTick()
    {
        if (FullscreenAppRunning()) { SetVisible(false); ticks++; return; }
        if (ticks % repositionEveryTicks == 0) FitIntoGap();
        SetVisible(true);
        if (ticks % raiseEveryTicks == 0) KeepInFront();
        AdvanceFrame();
        ticks++;
    }

    void SetVisible(bool show)
    {
        if (show == visible) return;
        ShowWindow(Handle, show ? SW_SHOWNOACTIVATE : SW_HIDE);
        visible = show;
    }

    void AdvanceFrame()
    {
        if (frame == 0) currentMood = mood.Wanted;  // every mood loops back to the same pose at frame 0
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
        var topLeft = new POINT { X = bounds.X + (bounds.Width - width) / 2, Y = bounds.Y + (bounds.Height - height) / 2 };
        ScreenToClient(taskbar, ref topLeft);
        placement = new Rectangle(topLeft.X, topLeft.Y, width, height);
        SetWindowPos(Handle, HWND_TOP, placement.X, placement.Y, placement.Width, placement.Height, SWP_NOACTIVATE);
    }

    void DrawFrame(IntPtr bitmap)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memoryDc = CreateCompatibleDC(screenDc);
        IntPtr previous = SelectObject(memoryDc, bitmap);
        try
        {
            var size = new SIZE { Cx = placement.Width, Cy = placement.Height };
            var src = new POINT { X = (moods[0].FrameSize.Width - placement.Width) / 2, Y = 0 };
            var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };
            UpdateLayeredWindow(Handle, screenDc, IntPtr.Zero, ref size, memoryDc, ref src, 0, ref blend, ULW_ALPHA);
        }
        finally
        {
            SelectObject(memoryDc, previous);
            DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    void KeepInFront()     // above the taskbar's own content, which is a sibling child window
    {
        SetWindowPos(Handle, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    static bool FullscreenAppRunning()
    {
        int state;
        if (SHQueryUserNotificationState(out state) != 0) return false;
        return state == QUNS_BUSY || state == QUNS_RUNNING_D3D_FULL_SCREEN || state == QUNS_PRESENTATION_MODE;
    }

    protected override void OnHandleChange()
    {
        if (!IsDocked) timer.Stop();
    }

    public void Dispose()
    {
        timer.Dispose();
        if (IsDocked) DestroyHandle();
    }
}

// Owns the tray icon, load tracking and sprites, and keeps an overlay docked in the taskbar,
// docking a fresh one whenever Explorer restarts.
public sealed class OverlayApp : ApplicationContext
{
    const int SAMPLE_EVERY_MS = 1000;

    readonly SpriteFrames[] moods;
    readonly int frameMs;
    readonly MoodTracker mood;
    readonly NotifyIcon tray;
    readonly Timer sampleTimer = new Timer { Interval = SAMPLE_EVERY_MS };
    TaskbarMoodOverlay overlay;

    public OverlayApp(SpriteFrames[] moods, string[] moodNames, int frameMs, int pinnedMood)
    {
        this.moods = moods;
        this.frameMs = frameMs;
        mood = new MoodTracker(moodNames, pinnedMood);
        tray = CreateTrayIcon();
        sampleTimer.Tick += (s, e) => OnSample();
        sampleTimer.Start();
        OnSample();
    }

    NotifyIcon CreateTrayIcon()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Restart Explorer (re-dock)", null, (s, e) => RestartExplorer());
        menu.Items.Add("Exit", null, (s, e) => ExitThread());
        return new NotifyIcon { Icon = SystemIcons.Application, Text = "taskbar overlay", ContextMenuStrip = menu, Visible = true };
    }

    void OnSample()
    {
        mood.Sample();
        DropOverlayIfTaskbarGone();
        if (overlay == null) DockOverlay();
        tray.Text = overlay != null ? mood.Status : "Can't dock: right-click > Restart Explorer";
    }

    // A fresh taskbar starts in the desktop band again, so the overlay can dock; Windows restarts the shell itself.
    static void RestartExplorer()
    {
        foreach (Process explorer in Process.GetProcessesByName("explorer"))
        {
            explorer.Kill();
            explorer.Dispose();
        }
    }

    void DropOverlayIfTaskbarGone()
    {
        if (overlay == null || overlay.IsDocked) return;
        overlay.Dispose();
        overlay = null;
    }

    void DockOverlay()
    {
        IntPtr taskbar = TaskbarMoodOverlay.FindTaskbar();
        if (taskbar == IntPtr.Zero) return;            // Explorer is still starting
        try
        {
            overlay = new TaskbarMoodOverlay(moods, frameMs, mood, taskbar);
        }
        catch (Win32Exception)   // refused once Start has lifted the taskbar; docks again after Explorer restarts
        {
        }
    }

    protected override void ExitThreadCore()
    {
        sampleTimer.Dispose();
        tray.Dispose();
        if (overlay != null) overlay.Dispose();
        mood.Dispose();
        foreach (SpriteFrames sprites in moods) sprites.Dispose();
        base.ExitThreadCore();
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
$app = New-Object OverlayApp -ArgumentList $sprites.Sprites, $sprites.Names, $sprites.FrameMs, $pinned
[System.Windows.Forms.Application]::Run($app)
