using System.Text.Json;
using System.Text.RegularExpressions;

namespace FoxyVPN.Core;

public static partial class TunnelConfiguration
{
    public const string InterfaceName = "FoxyVPN";
    public static string Create(int port)
    {
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        string[] bootstrap = ["fastly-masque.net", "firefox.com", "mozilla.org", "services.mozilla.com"];
        object Dns(string tag, string detour) => new
        {
            type = "https", tag, server = "1.1.1.1", server_port = 443,
            tls = new { enabled = true, server_name = "cloudflare-dns.com" }, detour
        };
        return JsonSerializer.Serialize(new
        {
            log = new { level = "info", timestamp = true },
            dns = new
            {
                servers = new[] { Dns("bootstrap-dns", "direct"), Dns("remote-dns", "proxy") },
                rules = new[] { new { domain_suffix = bootstrap, action = "route", server = "bootstrap-dns" } },
                final = "remote-dns", strategy = "prefer_ipv4", independent_cache = true, reverse_mapping = true
            },
            inbounds = new[] { new
            {
                type = "tun", tag = "tun-in", interface_name = InterfaceName,
                address = new[] { "172.19.0.1/30", "fdfe:dcba:9876::1/126" },
                mtu = 1400, stack = "system", auto_route = true, strict_route = true
            } },
            outbounds = new object[]
            {
                new { type = "socks", tag = "proxy", server = "127.0.0.1", server_port = port, version = "5" },
                new { type = "direct", tag = "direct" }
            },
            route = new
            {
                rules = new object[]
                {
                    new { action = "sniff" },
                    new { protocol = "dns", action = "hijack-dns" },
                    new { port = 53, action = "hijack-dns" },
                    new { process_name = new[] { "foxyvpn-proxy.exe" }, action = "route", outbound = "direct" },
                    new { ip_is_private = true, action = "route", outbound = "direct" },
                    new { network = "udp", action = "reject" }
                },
                final = "proxy", default_domain_resolver = "bootstrap-dns", auto_detect_interface = true
            }
        }, new JsonSerializerOptions { WriteIndented = true });
    }

    public static bool IsSessionToken(string value) => SessionPattern().IsMatch(value);
    public static bool IsLoginOrigin(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && uri.Host.Equals("accounts.firefox.com", StringComparison.OrdinalIgnoreCase)
        && uri.IsDefaultPort && uri.UserInfo.Length == 0;

    public static string Redact(string value)
    {
        var result = SensitivePattern().Replace(value, "[скрыто]");
        return result[..Math.Min(2000, result.Length)];
    }

    [GeneratedRegex(@"\A[0-9a-f]{64}\z")]
    private static partial Regex SessionPattern();
    [GeneratedRegex("(?i)\\b[0-9a-f]{64}\\b|\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b|(?:access_token|refresh_token|sessionToken|authorization|password)[\\s\"':=]+[^\\s,\"}]+")]
    private static partial Regex SensitivePattern();
}
