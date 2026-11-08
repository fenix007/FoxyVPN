using System.Diagnostics;
using FoxyVPN.Core;

namespace FoxyVPN.Windows;

internal static class SelfTest
{
    public static int Run()
    {
        var config = Path.Combine(Path.GetTempPath(), "foxyvpn-check-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(config, TunnelConfiguration.Create(1080));
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            VpnSession.CheckConfigAsync(config, timeout.Token).GetAwaiter().GetResult();
            using var proxy = new Process { StartInfo = VpnSession.BackendInfo("foxyvpn-proxy.exe", ["-help"]) };
            proxy.Start();
            var output = proxy.StandardOutput.ReadToEndAsync();
            var error = proxy.StandardError.ReadToEndAsync();
            proxy.WaitForExitAsync(timeout.Token).GetAwaiter().GetResult();
            Task.WhenAll(output, error).GetAwaiter().GetResult();
            if (!(output.Result + error.Result).Contains("-country")) throw new IOException("Backend CLI self-test failed.");
            using var job = new ProcessGroup();
            using var child = new Process { StartInfo = new ProcessStartInfo("cmd.exe", "/c ping -n 30 127.0.0.1 >nul") { UseShellExecute = false, CreateNoWindow = true } };
            child.Start();
            try { job.Add(child); }
            catch { child.Kill(true); throw; }
            job.Dispose();
            if (!child.WaitForExit(5000)) { child.Kill(true); throw new IOException("Job did not stop its child."); }
            Console.WriteLine("Windows configuration, Job Object and backend CLI checks passed.");
            return 0;
        }
        finally { File.Delete(config); }
    }
}
