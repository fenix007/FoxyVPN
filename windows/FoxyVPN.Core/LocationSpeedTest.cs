using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("FoxyVPN.Tests")]

namespace FoxyVPN.Core;

public sealed record LocationSpeedResult(long ReceivedBytes, TimeSpan Elapsed)
{
    public double MegabitsPerSecond => ReceivedBytes * 8d / Elapsed.TotalSeconds / 1_000_000;
}

/// <summary>A short, bounded download estimate through one location's SOCKS5 proxy.</summary>
public static class LocationSpeedTest
{
    public const int MaximumBytes = 5_000_000;
    public static readonly TimeSpan SampleDuration = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(15);
    private const string DownloadEndpoint = "https://speed.cloudflare.com/__down";

    public static async Task<LocationSpeedResult> MeasureAsync(int socksPort, CancellationToken cancellationToken)
    {
        if (socksPort is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(socksPort));
        using var handler = new SocketsHttpHandler
        {
            // An explicit proxy has no direct or system-proxy fallback. SOCKS5
            // sends the target hostname to the backend for remote DNS resolution.
            Proxy = new WebProxy(new Uri($"socks5://127.0.0.1:{socksPort}")),
            UseProxy = true,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(10)
        };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var endpoint = new Uri($"{DownloadEndpoint}?bytes={MaximumBytes}&cachebust={Guid.NewGuid():N}");
        return await MeasureAsync(client, endpoint, SampleDuration, RequestTimeout, cancellationToken).ConfigureAwait(false);
    }

    internal static async Task<LocationSpeedResult> MeasureAsync(HttpClient client, Uri endpoint,
        TimeSpan sampleDuration, TimeSpan requestTimeout, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(requestTimeout);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
            request.Headers.AcceptEncoding.ParseAdd("identity");
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK)
                throw new HttpRequestException($"Сервер теста скорости вернул HTTP {(int)response.StatusCode}.", null, response.StatusCode);
            if (response.Content.Headers.ContentEncoding.Any(encoding => !encoding.Equals("identity", StringComparison.OrdinalIgnoreCase)))
                throw new IOException("Сервер теста скорости вернул сжатые данные.");

            await using var input = await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
            using var sample = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token);
            sample.CancelAfter(sampleDuration);
            var watch = Stopwatch.StartNew();
            var buffer = new byte[64 * 1024];
            long received = 0;
            while (received < MaximumBytes)
            {
                int count;
                try
                {
                    count = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, MaximumBytes - received)), sample.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!deadline.IsCancellationRequested && sample.IsCancellationRequested && received > 0)
                {
                    // The sampling deadline intentionally interrupts a slow
                    // download. Network failures and premature EOF remain errors.
                    break;
                }
                if (count == 0) throw new IOException("Сервер теста скорости завершил загрузку раньше времени.");
                received += count;
            }
            watch.Stop();
            deadline.Token.ThrowIfCancellationRequested();
            return new LocationSpeedResult(received, watch.Elapsed);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("Сервер теста скорости не ответил вовремя.");
        }
    }
}
