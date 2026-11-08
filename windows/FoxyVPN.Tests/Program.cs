using System.Text;
using System.Text.Json;
using FoxyVPN.Core;

if (args.Length == 2 && args[0] == "--write-config")
{
    File.WriteAllText(args[1], TunnelConfiguration.Create(1080));
    return;
}
int passed = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new Exception("FAILED: " + name);
    Console.WriteLine("PASS " + name); passed++;
}
using (var config = JsonDocument.Parse(TunnelConfiguration.Create(1080)))
{
    var root = config.RootElement;
    var tun = root.GetProperty("inbounds")[0];
    Check(tun.GetProperty("strict_route").GetBoolean(), "Windows strict DNS routing enabled");
    Check(tun.GetProperty("address").EnumerateArray().Any(a => a.GetString()!.Contains(':')), "IPv6 route configured");
    Check(root.GetProperty("route").GetProperty("final").GetString() == "proxy", "default route uses VPN");
    Check(root.GetProperty("route").GetProperty("rules").EnumerateArray().Any(r =>
        r.TryGetProperty("process_name", out var p) && p[0].GetString() == "foxyvpn-proxy.exe"), "Windows backend bypass prevents recursion");
    Check(root.GetProperty("dns").GetProperty("final").GetString() == "remote-dns", "DNS defaults to proxy");
}
foreach (var port in new[] { -1, 0, 65536 })
{
    bool rejected = false;
    try { TunnelConfiguration.Create(port); } catch (ArgumentOutOfRangeException) { rejected = true; }
    Check(rejected, "invalid proxy port rejected: " + port);
}
Check(TunnelConfiguration.IsLoginOrigin("https://accounts.firefox.com/path"), "official login origin accepted");
foreach (var origin in new[] { "http://accounts.firefox.com", "https://accounts.firefox.com.attacker.test", "https://accounts.firefox.com:444", "https://attacker@accounts.firefox.com", "https://evil.accounts.firefox.com" })
    Check(!TunnelConfiguration.IsLoginOrigin(origin), "untrusted login origin rejected: " + origin);
Check(TunnelConfiguration.IsSessionToken(new string('a', 64)), "valid session accepted");
Check(!TunnelConfiguration.IsSessionToken(new string('a', 64) + "\n"), "trailing newline rejected");
Check(!TunnelConfiguration.Redact("sessionToken=" + new string('b', 64)).Contains(new string('b', 64)), "credentials redacted");
var meter = new TrafficMeter(1000, 2000);
meter.Begin(); meter.Sample(100, 200, TimeSpan.Zero); meter.Sample(1124, 712, TimeSpan.FromSeconds(2));
Check(meter.Received == 1024 && meter.Sent == 512 && meter.ReceiveRate == 512 && meter.TotalSent == 2512, "traffic deltas, rates and totals");
meter.Sample(1, 1, TimeSpan.FromSeconds(3)); meter.Sample(11, 21, TimeSpan.FromSeconds(4));
Check(meter.Received == 1034 && meter.Sent == 532, "adapter reset starts new baseline");
meter.Begin(); meter.Sample(0, 0, TimeSpan.FromSeconds(5)); meter.Sample(10, 20, TimeSpan.FromSeconds(6));
Check(meter.Received == 10 && meter.TotalReceived == 2044, "new session preserves lifetime totals");
const string directory = """
{"data":[
 {"country":{"code":"de","name":"Germany","cities":[{"servers":[{"hostname":"edge.test","port":443,"protocols":[{"name":"connect"}]}]}]}},
 {"country":{"code":"FI","name":"Finland","cities":[{"servers":[{"hostname":"edge.test","port":443,"quarantined":true}]}]}},
 {"country":{"code":"US","name":"United States","cities":[{"servers":[{"hostname":"edge.test","port":443,"protocols":[{"name":"wireguard"}]}]}]}}
]}
""";
var countries = ServerDirectory.Parse(Encoding.UTF8.GetBytes(directory));
Check(countries.Count == 1 && countries[0].Code == "DE", "directory filters quarantine and unsupported protocols");
Console.WriteLine($"{passed} checks passed.");
