using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace WacomLocalBridge;

internal sealed class BridgeStatusForm : Form
{
    private static readonly Color Green = Color.FromArgb(48, 168, 92);
    private static readonly Color Red = Color.FromArgb(211, 67, 72);
    private static readonly Color Gray = Color.FromArgb(151, 157, 166);

    private readonly BridgeRuntime _runtime;
    private readonly Label _heading;
    private readonly StatusDot _touchDot;
    private readonly Label _touchLabel;
    private readonly StatusDot _penDot;
    private readonly Label _penLabel;
    private readonly Label _metrics;
    private readonly FeedbackButton _openButton;
    private readonly FeedbackButton _quitButton;
    private readonly System.Windows.Forms.Timer _statusTimer;
    private Task<int>? _runtimeTask;
    private bool _allowClose;
    private bool _shutdownRequested;

    public BridgeStatusForm(BridgeRuntime runtime, string url)
    {
        _runtime = runtime;

        Text = "Wacom Input Test";
        ClientSize = new Size(400, 420);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.White;
        Font = new Font("Segoe UI", 10F, FontStyle.Regular, GraphicsUnit.Point);
        AutoScaleMode = AutoScaleMode.Dpi;

        var statusPanel = new RoundedPanel
        {
            Location = new Point(24, 24),
            Size = new Size(352, 230),
            FillColor = Color.FromArgb(250, 250, 251),
            BackColor = Color.FromArgb(250, 250, 251),
            BorderColor = Color.FromArgb(225, 227, 230),
            CornerRadius = 10
        };

        _heading = new Label
        {
            AutoSize = false,
            Location = new Point(24, 24),
            Size = new Size(304, 28),
            Text = "앱 시작 중…",
            Font = new Font("Segoe UI", 11F, FontStyle.Bold, GraphicsUnit.Point),
            BackColor = Color.Transparent
        };

        _touchDot = new StatusDot
        {
            Location = new Point(24, 83),
            Size = new Size(10, 10),
            DotColor = Gray
        };
        _touchLabel = CreateStatusLabel("터치 확인 중", new Point(44, 72));

        _penDot = new StatusDot
        {
            Location = new Point(24, 131),
            Size = new Size(10, 10),
            DotColor = Gray
        };
        _penLabel = CreateStatusLabel("펜 확인 중", new Point(44, 120));

        _metrics = new Label
        {
            AutoSize = false,
            Location = new Point(24, 168),
            Size = new Size(304, 46),
            Text = "이벤트 0  ·  브라우저 0\r\n누락: 입력 0  ·  클라이언트 0",
            ForeColor = Color.FromArgb(99, 105, 114),
            Font = new Font("Segoe UI", 9.25F, FontStyle.Regular, GraphicsUnit.Point),
            BackColor = Color.Transparent
        };

        statusPanel.Controls.AddRange([_heading, _touchDot, _touchLabel, _penDot, _penLabel, _metrics]);

        _openButton = new FeedbackButton
        {
            Location = new Point(24, 270),
            Size = new Size(352, 50),
            Text = "브라우저 열기",
            NormalColor = Color.FromArgb(232, 237, 245),
            HoverColor = Color.FromArgb(219, 227, 239),
            PressedColor = Color.FromArgb(199, 210, 226),
            TextColor = Color.FromArgb(41, 56, 77)
        };
        _openButton.Click += (_, _) => Program.OpenChrome(url);

        _quitButton = new FeedbackButton
        {
            Location = new Point(24, 336),
            Size = new Size(352, 50),
            Text = "종료",
            NormalColor = Color.FromArgb(199, 79, 84),
            HoverColor = Color.FromArgb(212, 93, 98),
            PressedColor = Color.FromArgb(173, 63, 68),
            TextColor = Color.White
        };
        _quitButton.Click += (_, _) => BeginShutdown();

        Controls.AddRange([statusPanel, _openButton, _quitButton]);
        AcceptButton = _openButton;

        _statusTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _statusTimer.Tick += (_, _) => RefreshStatus();
        _statusTimer.Start();
    }

    public void AttachRuntimeTask(Task<int> runtimeTask)
    {
        _runtimeTask = runtimeTask;
    }

    protected override void OnFormClosing(FormClosingEventArgs eventArgs)
    {
        if (_allowClose || _runtimeTask?.IsCompleted == true)
        {
            base.OnFormClosing(eventArgs);
            return;
        }

        eventArgs.Cancel = true;
        BeginShutdown();
        base.OnFormClosing(eventArgs);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _statusTimer.Dispose();
        }
        base.Dispose(disposing);
    }

    private static Label CreateStatusLabel(string text, Point location)
    {
        return new Label
        {
            AutoSize = false,
            Location = location,
            Size = new Size(284, 32),
            Text = text,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular, GraphicsUnit.Point),
            BackColor = Color.Transparent
        };
    }

    private void RefreshStatus()
    {
        var status = _runtime.GetStatus();
        if (status is not null)
        {
            _heading.Text = _shutdownRequested ? "앱 종료 중…" : "앱 실행 중";
            SetDeviceStatus(_touchDot, _touchLabel, "터치", status.Native.TouchReady);
            SetDeviceStatus(_penDot, _penLabel, "펜", status.Native.PenReady);
            _metrics.Text =
                $"이벤트 {status.Native.ProducedEvents:N0}  ·  브라우저 {status.WebSocketClients:N0}\r\n" +
                $"누락: 입력 {status.Native.DroppedInputEvents:N0}  ·  클라이언트 {status.DroppedClientMessages:N0}";
        }

        if (_runtime.StartupError is not null)
        {
            _heading.Text = "앱 시작 오류";
            _touchDot.DotColor = Red;
            _penDot.DotColor = Red;
            _touchLabel.Text = "터치 확인 불가";
            _penLabel.Text = "펜 확인 불가";
            _metrics.Text = _runtime.StartupError;
            _openButton.Enabled = false;
        }

        if (_runtimeTask?.IsCompleted != true)
        {
            return;
        }

        if (_runtime.StartupError is null)
        {
            _allowClose = true;
            Close();
        }
        else if (_shutdownRequested)
        {
            _allowClose = true;
            Close();
        }
    }

    private static void SetDeviceStatus(StatusDot dot, Label label, string name, bool ready)
    {
        dot.DotColor = ready ? Green : Red;
        label.Text = ready ? $"{name} 연결됨" : $"{name} 연결 오류";
    }

    private void BeginShutdown()
    {
        if (_shutdownRequested)
        {
            return;
        }

        _shutdownRequested = true;
        _heading.Text = "앱 종료 중…";
        _touchDot.DotColor = Gray;
        _penDot.DotColor = Gray;
        _openButton.Enabled = false;
        _quitButton.Enabled = false;
        _runtime.RequestStop();

        if (_runtimeTask?.IsCompleted == true)
        {
            _allowClose = true;
            Close();
        }
    }
}

internal sealed class StatusDot : Control
{
    private Color _dotColor = Color.Gray;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color DotColor
    {
        get => _dotColor;
        set
        {
            if (_dotColor == value) return;
            _dotColor = value;
            Invalidate();
        }
    }

    public StatusDot()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        TabStop = false;
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        eventArgs.Graphics.Clear(Parent?.BackColor ?? Color.White);
        using var brush = new SolidBrush(DotColor);
        eventArgs.Graphics.FillEllipse(brush, ClientRectangle);
    }
}

internal sealed class RoundedPanel : Panel
{
    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color FillColor { get; init; } = Color.White;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color BorderColor { get; init; } = Color.LightGray;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int CornerRadius { get; init; } = 10;

    public RoundedPanel()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
    }

    protected override void OnPaintBackground(PaintEventArgs eventArgs)
    {
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        eventArgs.Graphics.Clear(Parent?.BackColor ?? Color.White);
        using var path = CreateRoundedRectangle(ClientRectangle, CornerRadius);
        using var brush = new SolidBrush(FillColor);
        eventArgs.Graphics.FillPath(brush, path);
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = Rectangle.Inflate(ClientRectangle, -1, -1);
        using var path = CreateRoundedRectangle(bounds, CornerRadius);
        using var pen = new Pen(BorderColor, 1F);
        eventArgs.Graphics.DrawPath(pen, path);
    }

    internal static GraphicsPath CreateRoundedRectangle(Rectangle bounds, int radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal sealed class FeedbackButton : Button
{
    private bool _hovered;
    private bool _pressed;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color NormalColor { get; init; } = Color.Gainsboro;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color HoverColor { get; init; } = Color.LightGray;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color PressedColor { get; init; } = Color.Silver;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Color TextColor { get; init; } = Color.Black;

    public FeedbackButton()
    {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        UseVisualStyleBackColor = false;
        Cursor = Cursors.Hand;
        Font = new Font("Segoe UI", 10F, FontStyle.Bold, GraphicsUnit.Point);
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
    }

    protected override void OnMouseEnter(EventArgs eventArgs)
    {
        _hovered = true;
        Invalidate();
        base.OnMouseEnter(eventArgs);
    }

    protected override void OnMouseLeave(EventArgs eventArgs)
    {
        _hovered = false;
        _pressed = false;
        Invalidate();
        base.OnMouseLeave(eventArgs);
    }

    protected override void OnMouseDown(MouseEventArgs eventArgs)
    {
        if (eventArgs.Button == MouseButtons.Left) _pressed = true;
        Invalidate();
        base.OnMouseDown(eventArgs);
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        _pressed = false;
        Invalidate();
        base.OnMouseUp(eventArgs);
    }

    protected override void OnEnabledChanged(EventArgs eventArgs)
    {
        Cursor = Enabled ? Cursors.Hand : Cursors.Default;
        Invalidate();
        base.OnEnabledChanged(eventArgs);
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        eventArgs.Graphics.Clear(Parent?.BackColor ?? Color.White);
        var color = _pressed ? PressedColor : _hovered ? HoverColor : NormalColor;
        if (!Enabled) color = Color.FromArgb(140, color);

        var bounds = Rectangle.Inflate(ClientRectangle, -1, -1);
        using var path = RoundedPanel.CreateRoundedRectangle(bounds, 10);
        using var brush = new SolidBrush(color);
        eventArgs.Graphics.FillPath(brush, path);

        TextRenderer.DrawText(
            eventArgs.Graphics,
            Text,
            Font,
            bounds,
            Enabled ? TextColor : Color.FromArgb(145, TextColor),
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
            TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);

        if (Focused && ShowFocusCues)
        {
            var focusBounds = Rectangle.Inflate(bounds, -4, -4);
            ControlPaint.DrawFocusRectangle(eventArgs.Graphics, focusBounds, TextColor, color);
        }
    }
}
