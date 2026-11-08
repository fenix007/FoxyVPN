using System.Diagnostics;
using System.Text.Json;
using FoxyVPN.Core;

namespace FoxyVPN.Windows;

internal sealed class MainForm : Form
{
    private readonly ComboBox country = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 420 };
    private readonly Button login = new() { Text = "Войти в Firefox…", AutoSize = true };
    private readonly Button logout = new() { Text = "Выйти", AutoSize = true };
    private readonly Button connect = new() { Text = "Подключить VPN", AutoSize = true, Enabled = false };
    private readonly Label status = new() { Text = "VPN отключён", AutoSize = true };
    private readonly Label traffic = new() { AutoSize = true, MaximumSize = new Size(630, 0) };
    private readonly TextBox logs = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? startup;
    private VpnSession? vpn;
    private string? pendingSession;
    private bool signedIn, busy, closing, ticking;
    private readonly TrafficMeter meter;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private DateTime lastSaved;
    private static string StatisticsFile => Path.Combine(PrivateStorage.Root, "statistics.json");
    private static string CountryFile => Path.Combine(PrivateStorage.Root, "country.txt");

    public MainForm()
    {
        Text = "FoxyVPN — Windows"; Width = 720; Height = 620; MinimumSize = new Size(680, 520);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 8 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var i = 0; i < 7; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.Controls.Add(new Label { Text = "FoxyVPN", Font = new Font("Segoe UI", 24, FontStyle.Bold), AutoSize = true });
        var auth = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        auth.Controls.Add(login); auth.Controls.Add(logout); layout.Controls.Add(auth);
        layout.Controls.Add(new Label { Text = "Страна выхода", AutoSize = true, Margin = new Padding(3, 14, 3, 4) });
        layout.Controls.Add(country);
        var connection = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 16, 0, 12) };
        connection.Controls.Add(connect); connection.Controls.Add(status); layout.Controls.Add(connection);
        layout.Controls.Add(traffic);
        layout.Controls.Add(new Label { Text = "Журнал подключения", AutoSize = true, Margin = new Padding(3, 15, 3, 5) });
        layout.Controls.Add(logs); Controls.Add(layout);
        meter = LoadStatistics();
        try { signedIn = PrivateStorage.LoadTokens() is not null; }
        catch (Exception e) { Log("Не удалось прочитать сохранённый вход: " + e.Message); }
        UpdateTraffic(); UpdateControls();
        login.Click += (_, _) =>
        {
            using var window = new LoginForm();
            if (window.ShowDialog(this) == DialogResult.OK)
            { pendingSession = window.SessionToken; signedIn = true; status.Text = "Вход выполнен"; UpdateControls(); }
        };
        logout.Click += (_, _) =>
        {
            try { PrivateStorage.DeleteTokens(); pendingSession = null; signedIn = false; UpdateControls(); }
            catch (Exception e) { Log(e.Message); }
        };
        connect.Click += async (_, _) =>
        {
            if (busy) { startup?.Cancel(); return; }
            if (vpn is not null) { Disconnect("VPN отключён"); return; }
            await ConnectAsync();
        };
        country.SelectedIndexChanged += (_, _) => UpdateControls();
        Shown += async (_, _) => await LoadCountriesAsync();
        timer.Tick += (_, _) => Tick(); timer.Start();
        FormClosing += (_, _) => { closing = true; lifetime.Cancel(); startup?.Cancel(); Disconnect("VPN отключён"); timer.Dispose(); };
    }
    private async Task LoadCountriesAsync()
    {
        try
        {
            status.Text = "Загрузка стран…";
            var countries = await ServerDirectory.LoadAsync(lifetime.Token);
            country.Items.AddRange(countries.Cast<object>().ToArray());
            var saved = File.Exists(CountryFile) ? File.ReadAllText(CountryFile).Trim() : "DE";
            country.SelectedItem = countries.FirstOrDefault(c => c.Code == saved) ?? countries[0];
            status.Text = "VPN отключён";
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { status.Text = "Не удалось загрузить страны"; Log(e.Message); }
        UpdateControls();
    }
    private async Task ConnectAsync()
    {
        if (country.SelectedItem is not VPNCountry selected) return;
        busy = true; logs.Clear(); status.Text = "Подключение…"; meter.Begin(); UpdateTraffic();
        startup = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        UpdateControls();
        VpnSession? attempt = null;
        try
        {
            attempt = new VpnSession(Log); vpn = attempt;
            File.WriteAllText(CountryFile, selected.Code);
            await attempt.ConnectAsync(selected.Code, pendingSession, startup.Token);
            pendingSession = null;
            status.Text = "VPN подключён";
        }
        catch (OperationCanceledException) { Disconnect("VPN отключён"); }
        catch (Exception e) { Log(e.Message); Disconnect("Ошибка подключения"); }
        finally
        {
            busy = false; startup.Dispose(); startup = null; UpdateControls();
            if (closing) attempt?.Dispose();
        }
    }
    private void Disconnect(string reason)
    {
        var session = vpn; vpn = null;
        try { session?.Dispose(); }
        catch (Exception e) { Log(e.Message); }
        meter.Pause(); SaveStatistics();
        if (!closing) { status.Text = reason; UpdateTraffic(); UpdateControls(); }
    }
    private void Tick()
    {
        if (ticking || busy || vpn?.Connected != true) return;
        ticking = true;
        try
        {
            vpn.CheckHealth();
            var adapter = VpnSession.FindAdapter() ?? throw new IOException("VPN-интерфейс исчез.");
            var counters = adapter.GetIPStatistics();
            // TUN adapter direction is from the operating system's perspective.
            meter.Sample(counters.BytesReceived, counters.BytesSent, clock.Elapsed);
            UpdateTraffic();
            if (DateTime.UtcNow - lastSaved > TimeSpan.FromSeconds(5)) SaveStatistics();
        }
        catch (Exception e) { Log(e.Message); Disconnect("VPN отключён: ошибка"); }
        finally { ticking = false; }
    }
    private void UpdateControls()
    {
        if (closing) return;
        login.Enabled = logout.Enabled = !busy && vpn is null;
        logout.Enabled &= signedIn;
        country.Enabled = !busy && vpn is null;
        connect.Enabled = busy || vpn is not null || (signedIn && country.SelectedItem is VPNCountry);
        connect.Text = busy ? "Отменить" : vpn is not null ? "Отключить VPN" : "Подключить VPN";
    }
    private void UpdateTraffic() => traffic.Text =
        $"За соединение: ↓ {TrafficMeter.Format(meter.Received)}  ↑ {TrafficMeter.Format(meter.Sent)}\n" +
        $"Скорость: ↓ {TrafficMeter.Format(meter.ReceiveRate)}/с  ↑ {TrafficMeter.Format(meter.SendRate)}/с\n" +
        $"Всего: ↓ {TrafficMeter.Format(meter.TotalReceived)}  ↑ {TrafficMeter.Format(meter.TotalSent)}";
    private TrafficMeter LoadStatistics()
    {
        try
        {
            if (File.Exists(StatisticsFile))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(StatisticsFile));
                return new(doc.RootElement.GetProperty("received").GetInt64(), doc.RootElement.GetProperty("sent").GetInt64());
            }
        }
        catch (Exception e) { Log("Не удалось прочитать статистику: " + e.Message); }
        return new();
    }
    private void SaveStatistics()
    {
        try
        {
            PrivateStorage.CreateDirectory(PrivateStorage.Root);
            File.WriteAllText(StatisticsFile + ".tmp", JsonSerializer.Serialize(new { received = meter.TotalReceived, sent = meter.TotalSent }));
            File.Move(StatisticsFile + ".tmp", StatisticsFile, true); lastSaved = DateTime.UtcNow;
        }
        catch (Exception e) { Log("Не удалось сохранить статистику: " + e.Message); }
    }
    private void Log(string text)
    {
        if (closing || IsDisposed) return;
        if (InvokeRequired) { try { BeginInvoke(() => Log(text)); } catch (InvalidOperationException) { } return; }
        if (logs.TextLength > 100_000) logs.Text = logs.Text[^50_000..];
        logs.AppendText(TunnelConfiguration.Redact(text) + Environment.NewLine);
    }
}
