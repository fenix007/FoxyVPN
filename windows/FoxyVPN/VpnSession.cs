using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using FoxyVPN.Core;

namespace FoxyVPN.Windows;

internal sealed class VpnSession : IDisposable
{
    private readonly ProcessGroup group = new();
    private readonly List<Process> processes = [];
    private readonly string directory;
    private readonly Action<string> log;
    private bool disposed;
    private byte[]? lastSavedTokens;
    public bool Connected { get; private set; }
    private string TokenPath => Path.Combine(directory, ".firefox-vpn-tokens.json");
    public VpnSession(Action<string> log)
    {
        this.log = log;
        PrivateStorage.CreateDirectory(PrivateStorage.Root);
        directory = Path.Combine(PrivateStorage.Root, "run-" + Guid.NewGuid().ToString("N"));
        PrivateStorage.CreateDirectory(directory);
    }
    internal static ProcessStartInfo BackendInfo(string name, IEnumerable<string> arguments)
    {
        var path = Path.Combine(AppContext.BaseDirectory, name);
        if (!File.Exists(path)) throw new FileNotFoundException("Не найден компонент " + name, path);
        var info = new ProcessStartInfo(path)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = AppContext.BaseDirectory
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        // The Win32 job, rather than the Unix PPID watcher, owns child lifetime.
        info.Environment.Remove("FOXYVPN_PARENT_PID");
        info.Environment["FOXYVPN_NONINTERACTIVE"] = "1";
        return info;
    }
    private Process Start(string name, IEnumerable<string> args, Action<string>? onLine = null)
    {
        var info = BackendInfo(name, args);
        info.Environment["FOXYVPN_STATE_DIR"] = directory;
        var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        void Receive(object sender, DataReceivedEventArgs e)
        {
            if (e.Data is not { } line) return;
            onLine?.Invoke(line);
            log(TunnelConfiguration.Redact(line));
        }
        process.OutputDataReceived += Receive;
        process.ErrorDataReceived += Receive;
        try
        {
            process.Start();
            processes.Add(process);
            group.Add(process);
            process.BeginOutputReadLine(); process.BeginErrorReadLine();
            return process;
        }
        catch
        {
            if (processes.Contains(process)) { try { process.Kill(true); } catch (InvalidOperationException) { } }
            else process.Dispose();
            throw;
        }
    }
    public async Task ConnectAsync(string country, string? session, CancellationToken cancellationToken)
    {
        if (country.Length != 2 || !country.All(char.IsAsciiLetterUpper)) throw new ArgumentException("Некорректная страна.");
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start(); var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        var args = new List<string> { "-country", country, "-listen", $"127.0.0.1:{port}", "-verify-exit=true", "-status-file", Path.Combine(directory, "status.json") };
        if (session is not null)
        {
            if (!TunnelConfiguration.IsSessionToken(session)) throw new ArgumentException("Некорректный токен входа.");
            var sessionFile = Path.Combine(directory, "session.txt");
            await File.WriteAllTextAsync(sessionFile, session + "\n", cancellationToken);
            args.AddRange(["-session-token", sessionFile]);
        }
        else
        {
            var tokens = PrivateStorage.LoadTokens() ?? throw new InvalidOperationException("Войди в Firefox Account.");
            await File.WriteAllBytesAsync(TokenPath, tokens, cancellationToken);
        }
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var proxy = Start("foxyvpn-proxy.exe", args, line =>
        {
            if (line.Contains("SOCKS5 proxy started", StringComparison.Ordinal)) ready.TrySetResult();
        });
        var exited = proxy.WaitForExitAsync(cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(180));
        var winner = await Task.WhenAny(ready.Task, exited).WaitAsync(timeout.Token);
        if (winner != ready.Task || proxy.HasExited) throw new IOException("Не удалось запустить VPN. Проверь журнал и доступ аккаунта к Firefox VPN.");
        await ready.Task;
        SaveTokens();
        var config = Path.Combine(directory, "tunnel.json");
        await File.WriteAllTextAsync(config, TunnelConfiguration.Create(port), cancellationToken);
        await CheckConfigAsync(config, cancellationToken);
        var tunnel = Start("sing-box.exe", ["run", "-c", config]);
        for (var i = 0; i < 150; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (proxy.HasExited || tunnel.HasExited) throw new IOException("VPN-процесс завершился. Подробности в журнале.");
            if (FindAdapter() is not null) { Connected = true; return; }
            await Task.Delay(200, cancellationToken);
        }
        throw new TimeoutException("Windows не подтвердила запуск VPN-туннеля за 30 секунд.");
    }
    internal static async Task CheckConfigAsync(string path, CancellationToken token)
    {
        using var process = new Process { StartInfo = BackendInfo("sing-box.exe", ["check", "-c", path]) };
        process.Start();
        var output = process.StandardOutput.ReadToEndAsync(token);
        var error = process.StandardError.ReadToEndAsync(token);
        try { await process.WaitForExitAsync(token); }
        catch { try { process.Kill(true); } catch (InvalidOperationException) { } throw; }
        var text = await output + await error;
        if (process.ExitCode != 0) throw new IOException("Некорректная конфигурация: " + TunnelConfiguration.Redact(text));
    }
    public static NetworkInterface? FindAdapter() => NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n =>
        n.Name == TunnelConfiguration.InterfaceName && n.GetIPProperties().UnicastAddresses.Any(a => a.Address.ToString() == "172.19.0.1"));
    public void CheckHealth()
    {
        if (processes.Any(p => p.HasExited)) throw new IOException("VPN-процесс завершился. Соединение отключено.");
        var path = Path.Combine(directory, "status.json");
        if (File.Exists(path))
        {
            try
            {
                using var json = JsonDocument.Parse(File.ReadAllBytes(path));
                if (json.RootElement.TryGetProperty("accepting", out var accepting) && !accepting.GetBoolean())
                    throw new IOException("Истёк доступ к VPN. Подключись заново.");
            }
            catch (JsonException) { } // The backend replaces this file atomically.
        }
        SaveTokens();
    }
    private void SaveTokens()
    {
        if (!File.Exists(TokenPath)) return;
        var data = File.ReadAllBytes(TokenPath);
        using var json = JsonDocument.Parse(data);
        if (json.RootElement.TryGetProperty("access_token", out var access) && !string.IsNullOrEmpty(access.GetString())
            && (lastSavedTokens is null || !data.AsSpan().SequenceEqual(lastSavedTokens)))
        {
            PrivateStorage.SaveTokens(data);
            lastSavedTokens = data;
        }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; Connected = false;
        try { SaveTokens(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or System.Security.Cryptography.CryptographicException)
        { log("Не удалось сохранить вход."); }
        finally
        {
            // Closing the job also handles an unexpected GUI exit. Credential
            // persistence must never prevent process termination and route cleanup.
            group.Dispose();
            foreach (var process in processes)
            {
                try { if (!process.HasExited) { process.Kill(true); process.WaitForExit(3000); } }
                catch (InvalidOperationException) { }
                finally { process.Dispose(); }
            }
            PrivateStorage.Cleanup(directory);
        }
    }
}
