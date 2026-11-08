using System.Text.Json;

namespace FoxyVPN.Core;

public sealed record VPNCountry(string Code, string Name)
{
    public override string ToString() => $"{Name} ({Code})";
}

public static class ServerDirectory
{
    public const string Endpoint = "https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records";
    public const int MaximumBytes = 4 * 1024 * 1024;

    public static async Task<IReadOnlyList<VPNCountry>> LoadAsync(CancellationToken cancellationToken)
    {
        using var client = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(30) };
        using var response = await client.GetAsync(Endpoint, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > MaximumBytes) throw new InvalidDataException("Слишком большой список серверов.");
        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = await input.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (output.Length + count > MaximumBytes) throw new InvalidDataException("Слишком большой список серверов.");
            output.Write(buffer, 0, count);
        }
        return Parse(output.ToArray());
    }

    public static IReadOnlyList<VPNCountry> Parse(byte[] data)
    {
        if (data.Length > MaximumBytes) throw new InvalidDataException("Слишком большой список серверов.");
        using var json = JsonDocument.Parse(data);
        var countries = new Dictionary<string, VPNCountry>();
        foreach (var record in json.RootElement.GetProperty("data").EnumerateArray())
        {
            var country = record.TryGetProperty("country", out var nested) ? nested : record;
            var code = Text(country, "code").Trim().ToUpperInvariant();
            var name = Text(country, "name").Trim();
            if (code.Length != 2 || !code.All(char.IsAsciiLetterUpper) || name.Length == 0
                || name.Equals("CatchAll Anycast", StringComparison.OrdinalIgnoreCase)
                || !country.TryGetProperty("cities", out var cities)) continue;
            if (cities.EnumerateArray().Any(city => city.TryGetProperty("servers", out var servers)
                && servers.EnumerateArray().Any(Usable))) countries[code] = new(code, name);
        }
        if (countries.Count == 0) throw new InvalidDataException("Нет доступных стран.");
        return countries.Values.OrderBy(c => c.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static bool Usable(JsonElement server)
    {
        if (server.TryGetProperty("quarantined", out var quarantine) && quarantine.ValueKind == JsonValueKind.True) return false;
        var host = Text(server, "hostname");
        var port = Port(server);
        if (!server.TryGetProperty("protocols", out var protocols) || protocols.GetArrayLength() == 0) return Valid(host, port);
        return protocols.EnumerateArray().Any(p => Text(p, "name") == "connect"
            && Valid(string.IsNullOrWhiteSpace(Text(p, "host")) ? host : Text(p, "host"), Port(p) == 0 ? port : Port(p)));
    }
    private static string Text(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    private static int Port(JsonElement e) => e.TryGetProperty("port", out var p) && p.TryGetInt32(out var n) ? n : 0;
    private static bool Valid(string host, int port) => host.Length is > 0 and <= 253 && port is > 0 and <= 65535
        && host.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-');
}
