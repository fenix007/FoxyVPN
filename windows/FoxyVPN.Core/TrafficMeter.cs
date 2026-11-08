namespace FoxyVPN.Core;

public sealed class TrafficMeter
{
    public long Received { get; private set; }
    public long Sent { get; private set; }
    public long TotalReceived { get; private set; }
    public long TotalSent { get; private set; }
    public double ReceiveRate { get; private set; }
    public double SendRate { get; private set; }
    private (long Received, long Sent, TimeSpan Time)? previous;

    public TrafficMeter(long received = 0, long sent = 0)
    {
        TotalReceived = Math.Max(0, received);
        TotalSent = Math.Max(0, sent);
    }
    public void Begin() { Received = Sent = 0; previous = null; Pause(); }
    public void Pause() { ReceiveRate = SendRate = 0; }
    public void Sample(long received, long sent, TimeSpan time)
    {
        if (received < 0 || sent < 0) return;
        if (previous is { } p)
        {
            var elapsed = (time - p.Time).TotalSeconds;
            // Adapter recreation resets counters. Establish a new baseline.
            if (received < p.Received || sent < p.Sent || elapsed <= 0) { previous = (received, sent, time); Pause(); return; }
            var rx = received - p.Received;
            var tx = sent - p.Sent;
            Received += rx; Sent += tx; TotalReceived += rx; TotalSent += tx;
            ReceiveRate = rx / elapsed; SendRate = tx / elapsed;
        }
        previous = (received, sent, time);
    }
    public static string Format(double bytes)
    {
        string[] units = ["Б", "КиБ", "МиБ", "ГиБ", "ТиБ"];
        var index = 0;
        while (bytes >= 1024 && index < units.Length - 1) { bytes /= 1024; index++; }
        return $"{bytes:0.##} {units[index]}";
    }
}
