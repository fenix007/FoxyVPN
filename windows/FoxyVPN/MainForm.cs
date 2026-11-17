using System.Diagnostics;
using System.Text.Json;
using FoxyVPN.Core;

namespace FoxyVPN.Windows;

internal sealed class MainForm : Form
{
    private readonly ComboBox country = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 610, DropDownWidth = 610 };
    private readonly Button login = new() { Text = "Войти в Firefox…", AutoSize = true };
    private readonly Button logout = new() { Text = "Выйти", AutoSize = true };
    private readonly Button connect = new() { Text = "Подключить VPN", AutoSize = true, Enabled = false };
    private readonly Button testSelected = new() { Text = "Тест выбранной", AutoSize = true };
    private readonly Button testAll = new() { Text = "Тест всех локаций", AutoSize = true };
    private readonly Label testStatus = new() { Text = "Тест загрузки: до 5 МБ на локацию, расходует квоту VPN.", AutoSize = true, MaximumSize = new Size(630, 0) };
    private readonly Label status = new() { Text = "VPN отключён", AutoSize = true };
    private readonly Label traffic = new() { AutoSize = true, MaximumSize = new Size(630, 0) };
    private readonly TextBox logs = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? startup;
    private CancellationTokenSource? speedTest;
    private VpnSession? vpn;
    private VpnSession? probe;
    private string? pendingSession;
    private bool signedIn, busy, closing, ticking;
    private readonly TrafficMeter meter;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private DateTime lastSaved;
    private static string StatisticsFile => Path.Combine(PrivateStorage.Root, "statistics.json");
    private static string CountryFile => Path.Combine(PrivateStorage.Root, "country.txt");

    private sealed class LocationOption(VPNCountry location)
    {
        public VPNCountry Location { get; } = location;
        public string Measurement { get; set; } = "не проверено";
        public override string ToString() => $"{Location} — {Measurement}";
    }

    public MainForm()
    {
        Text = "FoxyVPN — Windows"; Width = 720; Height = 710; MinimumSize = new Size(680, 640);
        StartPosition = FormStartPosition.CenterScreen;
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font("Segoe UI", 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 10 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var i = 0; i < 9; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.Controls.Add(new Label { Text = "FoxyVPN", Font = new Font("Segoe UI", 24, FontStyle.Bold), AutoSize = true });
        var auth = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        auth.Controls.Add(login); auth.Controls.Add(logout); layout.Controls.Add(auth);
        layout.Controls.Add(new Label { Text = "Страна выхода", AutoSize = true, Margin = new Padding(3, 14, 3, 4) });
        country.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        layout.Controls.Add(country);
        var tests = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        tests.Controls.Add(testSelected); tests.Controls.Add(testAll); layout.Controls.Add(tests);
        layout.Controls.Add(testStatus);
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
        testSelected.Click += async (_, _) =>
        {
            if (country.SelectedItem is LocationOption selected) await TestLocationsAsync([selected]);
        };
        testAll.Click += async (_, _) =>
        {
            if (speedTest is not null) { speedTest.Cancel(); return; }
            await TestLocationsAsync(country.Items.Cast<LocationOption>().ToArray());
        };
        Shown += async (_, _) => await LoadCountriesAsync();
        timer.Tick += (_, _) => Tick(); timer.Start();
        FormClosing += (_, _) =>
        {
            closing = true; lifetime.Cancel(); startup?.Cancel(); speedTest?.Cancel();
            try { probe?.Dispose(); } catch (Exception e) { Log(e.Message); }
            Disconnect("VPN отключён"); timer.Dispose();
        };
    }
    private async Task LoadCountriesAsync()
    {
        try
        {
            status.Text = "Загрузка стран…";
            var countries = await ServerDirectory.LoadAsync(lifetime.Token);
            var options = countries.Select(c => new LocationOption(c)).ToArray();
            country.Items.AddRange(options);
            var saved = File.Exists(CountryFile) ? File.ReadAllText(CountryFile).Trim() : "DE";
            country.SelectedItem = options.FirstOrDefault(c => c.Location.Code == saved) ?? options[0];
            status.Text = "VPN отключён";
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { status.Text = "Не удалось загрузить страны"; Log(e.Message); }
        UpdateControls();
    }
    private async Task ConnectAsync()
    {
        if (speedTest is not null || country.SelectedItem is not LocationOption option) return;
        var selected = option.Location;
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
    private async Task TestLocationsAsync(IReadOnlyList<LocationOption> locations)
    {
        if (speedTest is not null || busy || vpn is not null || !signedIn || locations.Count == 0) return;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        speedTest = cancellation;
        UpdateControls();
        foreach (var location in locations) SetMeasurement(location, "ожидание…");
        var completed = 0;
        var successful = 0;
        try
        {
            foreach (var location in locations)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                var label = location.Location.ToString();
                testStatus.Text = $"Тест {completed + 1}/{locations.Count}: {label} — подключение…";
                SetMeasurement(location, "подключение…");
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(45));
                VpnSession? attempt = null;
                try
                {
                    attempt = new VpnSession(text => Log($"[Тест {location.Location.Code}] {text}"));
                    probe = attempt;
                    var port = await attempt.StartProxyAsync(location.Location.Code, pendingSession, deadline.Token);
                    pendingSession = null;
                    SetMeasurement(location, "измерение…");
                    if (!closing) testStatus.Text = $"Тест {completed + 1}/{locations.Count}: {label} — загрузка…";
                    var result = await LocationSpeedTest.MeasureAsync(port, deadline.Token);
                    SetMeasurement(location, $"↓ {result.MegabitsPerSecond:F1} Мбит/с");
                    Log($"[Тест {location.Location.Code}] {result.MegabitsPerSecond:F1} Мбит/с, {result.ReceivedBytes:N0} байт.");
                    successful++;
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
                {
                    SetMeasurement(location, "отменено");
                    throw;
                }
                catch (OperationCanceledException)
                {
                    SetMeasurement(location, "тайм-аут");
                    Log($"[Тест {location.Location.Code}] Превышено время ожидания.");
                }
                catch (TimeoutException e)
                {
                    SetMeasurement(location, "тайм-аут");
                    Log($"[Тест {location.Location.Code}] {e.Message}");
                }
                catch (Exception e)
                {
                    SetMeasurement(location, "ошибка");
                    Log($"[Тест {location.Location.Code}] {e.Message}");
                    if (e is FileNotFoundException) break;
                }
                finally
                {
                    try { attempt?.Dispose(); }
                    catch (Exception e) { Log(e.Message); }
                    if (ReferenceEquals(probe, attempt)) probe = null;
                }
                completed++;
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            foreach (var location in locations)
                if (location.Measurement == "ожидание…") SetMeasurement(location, "не проверено");
            speedTest = null;
            if (!closing)
            {
                testStatus.Text = $"{(cancellation.IsCancellationRequested ? "Тест остановлен" : "Тест завершён")}. Успешно: {successful}/{locations.Count}. Результаты — в списке локаций.";
                UpdateControls();
            }
        }
    }
    private void SetMeasurement(LocationOption location, string measurement)
    {
        location.Measurement = measurement;
        if (closing) return;
        var index = country.Items.IndexOf(location);
        if (index >= 0) country.Items[index] = location;
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
        var testing = speedTest is not null;
        login.Enabled = logout.Enabled = !busy && !testing && vpn is null;
        logout.Enabled &= signedIn;
        country.Enabled = !busy && vpn is null;
        connect.Enabled = !testing && (busy || vpn is not null || (signedIn && country.SelectedItem is LocationOption));
        connect.Text = busy ? "Отменить" : vpn is not null ? "Отключить VPN" : "Подключить VPN";
        testSelected.Enabled = !busy && !testing && vpn is null && signedIn && country.SelectedItem is LocationOption;
        testAll.Enabled = testing || (!busy && vpn is null && signedIn && country.Items.Count > 0);
        testAll.Text = testing ? "Остановить тест" : "Тест всех локаций";
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
