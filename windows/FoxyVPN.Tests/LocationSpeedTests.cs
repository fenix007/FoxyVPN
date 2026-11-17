using System.Net;
using System.Net.Sockets;
using System.Text;
using FoxyVPN.Core;

internal static class LocationSpeedTests
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        check(new LocationSpeedResult(1_000_000, TimeSpan.FromSeconds(2)).MegabitsPerSecond == 4,
            "download result converts bytes to decimal megabits per second");

        var large = new TestStream(LocationSpeedTest.MaximumBytes + 100_000);
        var result = await MeasureAsync(large);
        check(result.ReceivedBytes == LocationSpeedTest.MaximumBytes && large.ReadBytes == LocationSpeedTest.MaximumBytes,
            "download stops at 5 MB without reading excess bytes");
        check(result.Elapsed > TimeSpan.Zero && double.IsFinite(result.MegabitsPerSecond), "download measures elapsed transfer time");

        check(await ThrowsAsync<IOException>(() => MeasureAsync(new TestStream(1024))), "premature download EOF fails instead of reporting speed");
        check(await ThrowsAsync<IOException>(() => MeasureAsync(new TestStream(0))), "empty download fails instead of reporting zero speed");
        check(await ThrowsAsync<IOException>(() => MeasureAsync(new TestStream(1024, fail: true))), "network failure after data is not a successful sample");

        var slow = await MeasureAsync(new TestStream(8192, stall: true), sample: TimeSpan.FromMilliseconds(100));
        check(slow.ReceivedBytes == 8192 && slow.Elapsed >= TimeSpan.FromMilliseconds(50),
            "sampling deadline reports received bytes over the actual sample duration");
        check(await ThrowsAsync<TimeoutException>(() => MeasureAsync(new TestStream(0, stall: true), sample: TimeSpan.FromMilliseconds(50))),
            "sampling deadline with no data reports timeout");
        check(await ThrowsAsync<TimeoutException>(() => MeasureAsync(new TestStream(8192, stall: true), timeout: TimeSpan.FromMilliseconds(50))),
            "overall deadline is an error even after receiving data");

        using (var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(50)))
            check(await ThrowsAsync<OperationCanceledException>(() => MeasureAsync(new TestStream(8192, stall: true), token: cancel.Token)),
                "caller cancellation interrupts an active download");

        foreach (var code in new[] { HttpStatusCode.Forbidden, HttpStatusCode.Redirect })
        {
            var body = new TestStream(LocationSpeedTest.MaximumBytes);
            check(await ThrowsAsync<HttpRequestException>(() => MeasureAsync(body, code)) && body.ReadBytes == 0,
                $"HTTP {(int)code} cannot produce a speed result");
        }
        var compressed = new TestStream(LocationSpeedTest.MaximumBytes);
        check(await ThrowsAsync<IOException>(() => MeasureAsync(compressed, compressed: true)) && compressed.ReadBytes == 0,
            "compressed responses cannot inflate the measured download speed");

        foreach (var port in new[] { -1, 0, 65536 })
            check(await ThrowsAsync<ArgumentOutOfRangeException>(() => LocationSpeedTest.MeasureAsync(port, CancellationToken.None)),
                "invalid speed-test SOCKS port rejected: " + port);

        await CheckSocksRoutingAsync(check);
    }

    private static async Task<LocationSpeedResult> MeasureAsync(TestStream stream, HttpStatusCode status = HttpStatusCode.OK,
        TimeSpan? sample = null, TimeSpan? timeout = null, CancellationToken token = default, bool compressed = false)
    {
        using var client = new HttpClient(new ResponseHandler(() =>
        {
            var response = new HttpResponseMessage(status) { Content = new StreamContent(stream) };
            if (compressed) response.Content.Headers.ContentEncoding.Add("gzip");
            return response;
        })) { Timeout = Timeout.InfiniteTimeSpan };
        return await LocationSpeedTest.MeasureAsync(client, new Uri("https://download.test/data"),
            sample ?? TimeSpan.FromSeconds(2), timeout ?? TimeSpan.FromSeconds(3), token);
    }

    private static async Task<bool> ThrowsAsync<T>(Func<Task<LocationSpeedResult>> action) where T : Exception
    {
        try { await action(); return false; }
        catch (T) { return true; }
    }

    private static async Task CheckSocksRoutingAsync(Action<bool, string> check)
    {
        // Reject at the SOCKS layer: no packets reach Cloudflare or public DNS.
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var proxy = Task.Run(async () =>
        {
            using var connection = await listener.AcceptTcpClientAsync(timeout.Token);
            await using var stream = connection.GetStream();
            var greeting = new byte[2];
            await stream.ReadExactlyAsync(greeting, timeout.Token);
            var methods = new byte[greeting[1]];
            await stream.ReadExactlyAsync(methods, timeout.Token);
            await stream.WriteAsync(new byte[] { 5, 0 }, timeout.Token);
            var header = new byte[5];
            await stream.ReadExactlyAsync(header, timeout.Token);
            if (header[0] != 5 || header[1] != 1 || header[3] != 3)
                throw new IOException("Expected a SOCKS5 hostname CONNECT request.");
            var target = new byte[header[4] + 2];
            await stream.ReadExactlyAsync(target, timeout.Token);
            var hostname = Encoding.ASCII.GetString(target.AsSpan(0, target.Length - 2));
            var destinationPort = (target[^2] << 8) | target[^1];
            await stream.WriteAsync(new byte[] { 5, 5, 0, 1, 0, 0, 0, 0, 0, 0 }, timeout.Token);
            return greeting[0] == 5 && hostname == "speed.cloudflare.com" && destinationPort == 443;
        });
        var failed = await ThrowsAsync<HttpRequestException>(() => LocationSpeedTest.MeasureAsync(port, timeout.Token));
        check(await proxy && failed, "speed test uses SOCKS5 remote DNS and fails when that proxy rejects the target");
    }

    private sealed class ResponseHandler(Func<HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(response());
        }
    }

    private sealed class TestStream(long available, bool stall = false, bool fail = false) : Stream
    {
        public long ReadBytes { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (ReadBytes < available)
            {
                var count = (int)Math.Min(buffer.Length, available - ReadBytes);
                buffer.Span[..count].Clear();
                ReadBytes += count;
                return count;
            }
            if (fail) throw new IOException("Connection reset during the download.");
            if (stall) await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return 0;
        }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
