using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace Guardian.Windows;

internal sealed class TrayMenu : Forms.ContextMenuStrip
{
    private int generation;
    public TrayMenu() => AutoClose = true;

    protected override void OnOpened(EventArgs e)
    {
        var opened = ++generation;
        base.OnOpened(e);
        // Activate the visible popup, rather than relying on NotifyIcon's hidden
        // owner window. This runs only for an explicitly opened tray menu.
        if (IsDisposed || Disposing || !IsHandleCreated) return;
        BeginInvoke((Action)(() =>
        {
            if (IsDisposed || opened != generation || !Visible) return;
            SetForegroundWindow(Handle);
            Focus();
        }));
    }

    protected override void OnLostFocus(EventArgs e)
    {
        base.OnLostFocus(e);
        if (!IsHandleCreated || IsDisposed || Disposing) return;
        var opened = generation;
        BeginInvoke((Action)(() =>
        {
            if (!IsDisposed && opened == generation && Visible && !ContainsFocus && !Items.OfType<Forms.ToolStripDropDownItem>().Any(item => item.HasDropDownItems && item.DropDown.Visible))
                Close(Forms.ToolStripDropDownCloseReason.AppFocusChange);
        }));
    }

    protected override void OnClosed(Forms.ToolStripDropDownClosedEventArgs e)
    {
        generation++;
        base.OnClosed(e);
    }

    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
}
