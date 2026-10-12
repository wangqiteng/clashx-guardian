using Guardian.Core;
using Forms = System.Windows.Forms;

namespace Guardian.Windows;

internal sealed class SettingsDialog : Forms.Form
{
    private readonly Forms.TextBox address = new() { Dock = Forms.DockStyle.Fill };
    private readonly Forms.TextBox secret = new() { Dock = Forms.DockStyle.Fill, UseSystemPasswordChar = true };
    private readonly Forms.ComboBox group = new() { Dock = Forms.DockStyle.Fill, DropDownStyle = Forms.ComboBoxStyle.DropDownList };
    private readonly Forms.CheckBox consent = new() { Text = "我确认这是 iKuuu 使用的 Controller 和路由组，允许故障后自动切换（排除台湾节点）", AutoSize = true, MaximumSize = new System.Drawing.Size(625, 0) };
    private readonly Forms.Label status = new() { AutoSize = true, MaximumSize = new System.Drawing.Size(620, 0) };
    private readonly Forms.Button test = new() { Text = "验证并读取策略组", AutoSize = true };
    private readonly Forms.Button save = new() { Text = "保存", AutoSize = true };
    private readonly Forms.CheckBox nativeConsent = new() { Text = "启用 iKuuu 0.17.5 官方界面自动测速与切换（无需 Controller，排除台湾节点）", AutoSize = true, MaximumSize = new System.Drawing.Size(625, 0) };
    private readonly CancellationTokenSource lifetime = new();
    private string verifiedAddress = "", verifiedSecret = "";
    public Settings Result { get; private set; }

    public SettingsDialog(Settings settings)
    {
        Result = settings;
        Text = "配置自动切换";
        AutoScaleMode = Forms.AutoScaleMode.Dpi;
        ClientSize = new System.Drawing.Size(670, 480);
        FormBorderStyle = Forms.FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        StartPosition = Forms.FormStartPosition.CenterScreen;
        var layout = new Forms.TableLayoutPanel { Dock = Forms.DockStyle.Fill, AutoScroll = true, Padding = new Forms.Padding(16), ColumnCount = 1, RowCount = 11 };
        layout.Controls.Add(new Forms.Label { Text = "官方界面模式支持 iKuuu 0.17.5，需要可交互的 Windows 桌面。\n若另有可用 Controller，可验证后启用接口模式；接口模式优先。", AutoSize = true, MaximumSize = new System.Drawing.Size(630, 0) });
        layout.Controls.Add(nativeConsent);
        nativeConsent.Checked = settings.AllowUISwitch;
        layout.Controls.Add(new Forms.Label { Text = "可选：本机 Controller 接口地址", AutoSize = true }); layout.Controls.Add(address);
        layout.Controls.Add(new Forms.Label { Text = "密钥（如果客户端有设置；使用 Windows 用户加密保存）", AutoSize = true }); layout.Controls.Add(secret);
        layout.Controls.Add(test); layout.Controls.Add(group); layout.Controls.Add(consent); layout.Controls.Add(status); layout.Controls.Add(save);
        Controls.Add(layout);
        address.Text = settings.ControllerUrl;
        try { secret.Text = Storage.ReadSecret(); } catch { status.Text = "原密钥无法解密，请重新填写"; }
        consent.Checked = settings.AllowSwitch;
        test.Click += async (_, _) => await VerifyAsync();
        save.Click += (_, _) => SaveSettings();
        FormClosed += (_, _) => lifetime.Cancel();
    }

    private async Task VerifyAsync()
    {
        test.Enabled = false; save.Enabled = false; group.Items.Clear();
        verifiedAddress = ""; verifiedSecret = "";
        var target = address.Text.Trim(); var password = secret.Text;
        try
        {
            using var controller = new ClashController(target, password);
            var nodes = await controller.ReadAsync(lifetime.Token);
            foreach (var node in nodes.Values.Where(n => n.Type == "Selector" && n.All != null)) group.Items.Add(node.Name);
            verifiedAddress = target; verifiedSecret = password;
            if (group.Items.Contains(Result.Group)) group.SelectedItem = Result.Group;
            else if (group.Items.Count == 1) group.SelectedIndex = 0;
            status.Text = $"读到 {group.Items.Count} 个手动策略组。请选择实际承载 Codex 流量的组；程序无法推断全部路由规则。";
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex) { status.Text = "接口验证失败（" + ex.GetType().Name + "）。可取消 Controller 勾选，使用官方界面模式。"; }
        finally { if (!IsDisposed) { test.Enabled = true; save.Enabled = true; } }
    }

    private void SaveSettings()
    {
        try
        {
            if (consent.Checked && (verifiedAddress != address.Text.Trim() || verifiedSecret != secret.Text || group.SelectedItem == null))
                throw new ArgumentException("请先验证当前地址和密钥，并选择策略组");
            var updated = Result with { ControllerUrl = address.Text.Trim(), Group = group.SelectedItem as string ?? "", AllowSwitch = consent.Checked, AllowUISwitch = nativeConsent.Checked };
            Storage.Save(updated, secret.Text);
            Result = updated;
            DialogResult = Forms.DialogResult.OK;
            Close();
        }
        catch (Exception ex) { status.Text = ex is ArgumentException ? ex.Message : "保存失败：" + ex.GetType().Name; }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { lifetime.Cancel(); lifetime.Dispose(); }
        base.Dispose(disposing);
    }
}
