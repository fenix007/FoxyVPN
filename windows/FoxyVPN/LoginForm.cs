using System.Diagnostics;
using System.Text.Json;
using FoxyVPN.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace FoxyVPN.Windows;

internal sealed class LoginForm : Form
{
    private readonly WebView2 web = new() { Dock = DockStyle.Fill };
    private readonly Label status = new() { Dock = DockStyle.Top, Height = 52, Text = "Вход через accounts.firefox.com. Используй пароль Mozilla; вход через Google/Apple не поддерживается.", Padding = new Padding(8) };
    private readonly string profile = Path.Combine(PrivateStorage.Root, "login-" + Guid.NewGuid().ToString("N"));
    private readonly CancellationTokenSource cancellation = new();
    private ProcessGroup? group;
    private bool verifying;
    public string? SessionToken { get; private set; }
    public LoginForm()
    {
        Text = "Firefox Account — FoxyVPN"; Width = 800; Height = 760;
        StartPosition = FormStartPosition.CenterParent;
        Controls.Add(web); Controls.Add(status);
        Shown += async (_, _) => await InitializeAsync();
        FormClosed += (_, _) =>
        {
            cancellation.Cancel(); group?.Dispose(); web.Dispose();
            // WebView2 can release its profile a little later than the control.
            _ = Task.Run(async () =>
            {
                for (var i = 0; i < 20 && Directory.Exists(profile); i++)
                { PrivateStorage.Cleanup(profile); await Task.Delay(500); }
            });
        };
    }
    private async Task InitializeAsync()
    {
        try
        {
            PrivateStorage.CreateDirectory(profile);
            var environment = await CoreWebView2Environment.CreateAsync(null, profile);
            if (IsDisposed) return;
            await web.EnsureCoreWebView2Async(environment);
            if (IsDisposed) return;
            var core = web.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false;
            core.Settings.IsGeneralAutofillEnabled = false;
            core.Settings.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:159.0) Gecko/20100101 Firefox/159.0";
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.NewWindowRequested += (_, e) => e.Handled = true;
            core.NavigationStarting += (_, e) =>
            {
                if (!AllowedNavigation(e.Uri)) e.Cancel = true;
            };
            core.WebMessageReceived += Receive;
            await core.AddScriptToExecuteOnDocumentCreatedAsync("""
                (() => {
                  if (window !== window.top || location.origin !== 'https://accounts.firefox.com') return;
                  if (window.__foxyHooked) return;
                  window.__foxyHooked = true;
                  function forward(event) {
                    try {
                      let message = event.detail;
                      if (typeof message === 'string') message = JSON.parse(message);
                      if (message && message.message) window.chrome.webview.postMessage(message);
                    } catch (_) {}
                  }
                  window.addEventListener('WebChannelMessageToChrome', forward);
                  document.addEventListener('WebChannelMessageToChrome', forward);
                  window.chrome.webview.addEventListener('message', event => {
                    window.dispatchEvent(new CustomEvent('WebChannelMessageToContent', {detail:event.data}));
                    document.dispatchEvent(new CustomEvent('WebChannelMessageToContent', {detail:event.data}));
                  });
                })();
                """);
            core.Navigate("https://accounts.firefox.com/?context=fx_desktop_v3&service=sync&action=email");
        }
        catch (Exception e) when (!IsDisposed)
        { status.Text = "Не удалось открыть вход. Установи Microsoft Edge WebView2 Runtime. " + TunnelConfiguration.Redact(e.Message); }
    }
    private static bool AllowedNavigation(string source)
    {
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri) || uri.Scheme != "https") return false;
        return new[] { "accounts.firefox.com", "firefox.com", "mozilla.org" }
            .Any(host => uri.Host == host || uri.Host.EndsWith("." + host, StringComparison.OrdinalIgnoreCase));
    }
    private async void Receive(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!TunnelConfiguration.IsLoginOrigin(e.Source) || !TunnelConfiguration.IsLoginOrigin(web.Source?.ToString() ?? "")) return;
        try
        {
            if (e.WebMessageAsJson.Length > 65536) return;
            using var json = JsonDocument.Parse(e.WebMessageAsJson);
            var envelope = json.RootElement;
            if (!envelope.TryGetProperty("message", out var message) || !message.TryGetProperty("command", out var cmd)) return;
            var command = cmd.GetString();
            object reply = command == "fxaccounts:fxa_status" ? new { capabilities = new { }, signedInUser = (object?)null } : new { ok = true };
            if (message.TryGetProperty("messageId", out var messageId))
                web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new
                {
                    id = envelope.TryGetProperty("id", out var id) ? id.Clone() : (object)"account_updates",
                    message = new { command, messageId = messageId.Clone(), data = reply }
                }));
            if (command is not ("fxaccounts:login" or "fxaccounts:oauth_login" or "fxaccounts:verified") || verifying) return;
            if (!message.TryGetProperty("data", out var data)) return;
            var token = data.TryGetProperty("sessionToken", out var session) ? session.GetString()
                : data.TryGetProperty("token", out var alternate) ? alternate.GetString() : null;
            if (token is null || !TunnelConfiguration.IsSessionToken(token)) return;
            verifying = true;
            status.Text = "Подтверди вход на странице или в письме Mozilla. Окно закроется после проверки.";
            group = new ProcessGroup();
            var info = VpnSession.BackendInfo("foxyvpn-proxy.exe", ["-wait-session-confirmed"]);
            info.RedirectStandardInput = true;
            using var process = new Process { StartInfo = info };
            process.Start();
            try { group.Add(process); }
            catch { process.Kill(true); throw; }
            var output = process.StandardOutput.ReadToEndAsync(cancellation.Token);
            var error = process.StandardError.ReadToEndAsync(cancellation.Token);
            await process.StandardInput.WriteAsync(token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(cancellation.Token);
            await Task.WhenAll(output, error);
            if (process.ExitCode != 0) throw new IOException("Подтверждение входа не завершено. Попробуй войти заново.");
            SessionToken = token;
            DialogResult = DialogResult.OK;
            Close();
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!IsDisposed) status.Text = TunnelConfiguration.Redact(error.Message); }
        finally { verifying = false; group?.Dispose(); group = null; }
    }
}
