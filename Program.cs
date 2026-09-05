// tait-cli: a small shell for a Tait TM8100/TM8200 mobile radio over its CCDI serial port.
//
//   tait-cli <port> [--baud N]              interactive shell
//   tait-cli <port> [--baud N] <command>    run one command and exit

using M0LTE.Radio.Tait;

const int DefaultBaud = 28800;
const int Quit = -1;

if (args.Length == 0 || args[0] is "-h" or "--help" or "help")
{
    PrintUsage();
    return args.Length == 0 ? 1 : 0;
}

var port = args[0];
var baud = DefaultBaud;
var command = new List<string>();
for (var i = 1; i < args.Length; i++)
{
    if (args[i] is "--baud" or "-b")
    {
        if (i + 1 >= args.Length || !int.TryParse(args[i + 1], out baud) || baud <= 0)
        {
            Console.Error.WriteLine("--baud needs a number, e.g. --baud 19200");
            return 1;
        }
        i++;
    }
    else
    {
        command.Add(args[i]);
    }
}

if (!OperatingSystem.IsWindows() && !File.Exists(port))
{
    Console.Error.WriteLine($"No such serial device: {port}");
    return 2;
}

TaitCcdiRadio radio;
try
{
    radio = TaitCcdiRadio.Open(port, baud);
}
catch (Exception ex)
{
    Console.Error.WriteLine($"Cannot open {port}: {ex.Message}");
    return 2;
}

// Ctrl-C stops the command in progress; at the prompt it ends the shell.
CancellationTokenSource? running = null;
var shell = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    (running ?? shell).Cancel();
};

TaitRadioIdentity? identity = null;

await using (radio)
{
    if (command.Count > 0)
    {
        var code = await RunAsync(command.ToArray());
        return code == Quit ? 0 : code;
    }

    // Interactive: prove the link before offering a prompt.
    try
    {
        await WithRetryAsync(async () => identity = await radio.QueryIdentityAsync(shell.Token));
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        Console.Error.WriteLine($"Failed: {Describe(ex)}");
        return 3;
    }

    Console.WriteLine($"{identity.ProductName}, serial {identity.SerialNumber}, firmware {Firmware(identity)}, on {port} at {baud} baud.");
    Console.WriteLine("Type help for commands, quit to leave.");

    while (!shell.IsCancellationRequested)
    {
        Console.Write("tait> ");
        var line = await ReadLineAsync(shell.Token);
        if (line is null)
        {
            Console.WriteLine();
            break;
        }

        var argv = line.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (argv.Length == 0) continue;
        if (await RunAsync(argv) == Quit) break;
    }

    return 0;
}

async Task<int> RunAsync(string[] argv)
{
    using var cts = new CancellationTokenSource();
    running = cts;
    var ct = cts.Token;
    var name = argv[0].ToLowerInvariant();
    switch (name)
    {
        case "help" or "?": PrintCommands(); return 0;
        case "quit" or "exit" or "q": return Quit;
    }

    try
    {
        await WithRetryAsync(() => name switch
        {
            "info" => InfoAsync(ct),
            "version" => VersionAsync(ct),
            "channel" => ChannelAsync(ct, explainFrequency: false),
            "freq" or "frequency" => ChannelAsync(ct, explainFrequency: true),
            "rssi" or "signal" => RssiAsync(ct),
            "watch" => WatchAsync(argv, ct),
            "display" => DisplayAsync(ct),
            "temp" => TempAsync(ct),
            _ => throw new ArgumentException($"Unknown command '{argv[0]}'. Type help for the list."),
        });
        return 0;
    }
    catch (ArgumentException ex)
    {
        Console.WriteLine(ex.Message);
        return 1;
    }
    catch (OperationCanceledException)
    {
        Console.WriteLine("Stopped.");
        return 130;
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Failed: {Describe(ex)}");
        return 3;
    }
    finally
    {
        running = null;
    }
}

// Bytes the radio received at the wrong baud rate (typically from a previous attempt
// at another rate) sit in its command buffer with no terminator and corrupt the next
// valid frame, which the radio rejects with a checksum error. One retry clears it.
async Task WithRetryAsync(Func<Task> action)
{
    try
    {
        await action();
    }
    catch (TaitCcdiException ex) when (ex.Error.Describe().Contains("checksum", StringComparison.OrdinalIgnoreCase))
    {
        Console.WriteLine("The radio reported a checksum error, usually stale bytes in its command buffer. Retrying once.");
        await action();
    }
}

async Task<TaitRadioIdentity> IdentityAsync(CancellationToken ct) => identity ??= await radio.QueryIdentityAsync(ct);

async Task InfoAsync(CancellationToken ct)
{
    var id = await IdentityAsync(ct);
    Console.WriteLine($"Model:     {id.ProductName} (type {id.RuType}, model {id.RuModel}, tier {id.RuTier})");
    Console.WriteLine($"Serial:    {id.SerialNumber}");
    Console.WriteLine($"CCDI:      {id.CcdiVersion}");
    Console.WriteLine($"Firmware:  {Firmware(id)}");
    foreach (var (key, label) in new[] { ("02", "Database"), ("03", "FPGA"), ("00", "Product") })
    {
        if (id.Versions.TryGetValue(key, out var value)) Console.WriteLine($"{label + ":",-11}{value}");
    }
    foreach (var (key, value) in id.Versions.Where(kv => kv.Key is not ("00" or "01" or "02" or "03")).OrderBy(kv => kv.Key))
    {
        Console.WriteLine($"{"Record " + key + ":",-11}{value}");
    }
    Console.WriteLine($"Band:      {BandText(id.Band)}");
}

async Task VersionAsync(CancellationToken ct)
{
    var id = await IdentityAsync(ct);
    Console.WriteLine($"Firmware {Firmware(id)}, CCDI {id.CcdiVersion}");
}

async Task ChannelAsync(CancellationToken ct, bool explainFrequency)
{
    var ch = await radio.QueryCurrentChannelAsync(ct);
    var kind = ch.Kind switch
    {
        '0' => "single channel",
        '1' => "scan/vote group",
        '2' => "captured within a group",
        '3' => "temporary channel",
        '9' => "not available",
        var k => $"kind {k}",
    };
    var zone = ch.Zone is { } z ? $", zone {z}" : "";
    Console.WriteLine($"Channel: {ch.ChannelId}{zone} ({kind})");

    if (!explainFrequency) return;
    var id = await IdentityAsync(ct);
    Console.WriteLine($"Band:    {BandText(id.Band)}");
    Console.WriteLine("The tuned frequency itself cannot be read over CCDI. Try 'display' to see what the control head shows.");
}

async Task RssiAsync(CancellationToken ct)
{
    var now = await radio.ReadRssiDbmAsync(ct);
    var avg = await radio.ReadAveragedRssiDbmAsync(ct);
    Console.WriteLine($"Signal: {now:0.0} dBm ({SMeter(now)}), radio's running average {avg:0.0} dBm ({SMeter(avg)})");
}

async Task WatchAsync(string[] argv, CancellationToken ct)
{
    var seconds = argv.Length > 1 && double.TryParse(argv[1], out var s) && s > 0 ? s : 0.5;
    Console.WriteLine("Reading the signal level; press Ctrl-C to stop.");
    while (true)
    {
        var now = await radio.ReadRssiDbmAsync(ct);
        Console.WriteLine($"{DateTime.Now:HH:mm:ss.f}  {now,7:0.0} dBm  {SMeter(now),-6} {Bar(now)}");
        await Task.Delay(TimeSpan.FromSeconds(seconds), ct);
    }
}

async Task DisplayAsync(CancellationToken ct)
{
    IReadOnlyList<M0LTE.Radio.Tait.Ccdi.CcdiDisplayMessage> elements;
    try
    {
        elements = await radio.QueryDisplayAsync(ct);
    }
    catch (TaitCcdiException ex)
    {
        // A radio without a display head answers the display query with a parameter error.
        Console.WriteLine($"This radio has no readable display (it answered: {ex.Error.Describe()}).");
        return;
    }
    // A text element's payload is 9 hex characters of position/font followed by the text.
    var lines = elements
        .Where(e => e.Kind == '1')
        .Select(e => e.Payload.Length > 9 ? e.Payload[9..] : e.Payload)
        .Where(t => t.Length > 0)
        .ToList();
    if (lines.Count == 0)
    {
        Console.WriteLine("Nothing readable on the display (the radio may have no control head).");
        return;
    }
    foreach (var line in lines) Console.WriteLine(line);
}

async Task TempAsync(CancellationToken ct)
{
    var t = await radio.ReadPaTemperatureAsync(ct);
    Console.WriteLine(t.Celsius is { } c
        ? $"PA temperature: {c} C (sensor {t.AdcMillivolts} mV)"
        : $"PA temperature sensor: {t.AdcMillivolts} mV (this model does not report degrees)");
}

string Describe(Exception ex) => ex switch
{
    TaitCcdiException e => $"the radio rejected the command ({e.Error.Describe()})",
    TimeoutException => $"""
        no reply from the radio on {port} at {baud} baud.
        Check the cable, then in the Tait programming software set:
          Data -> General -> Powerup State: Command Mode
          Data -> Serial Communications -> Baud Rate: {baud} (the rate this tool is using; change it with --baud)
          Data -> Serial Communications -> Flow Control: None
          Data -> Serial Communications -> Data Port: Mic, Aux or Internal Options, whichever socket the cable is in
        """,
    _ => ex.Message,
};

static string Firmware(TaitRadioIdentity id) => id.Versions.TryGetValue("01", out var fw) ? fw : "unknown";

static string BandText(TaitBand? band) => band is null
    ? "unknown"
    : $"{band.MinHz / 1e6:0.###}-{band.MaxHz / 1e6:0.###} MHz{(band.AmateurBand is null ? "" : $" ({band.AmateurBand})")}";

// IARU Region 1 convention above 30 MHz: S9 is -93 dBm and each S-point is 6 dB.
static string SMeter(float dbm)
{
    var overS9 = dbm + 93f;
    if (overS9 >= 0) return overS9 < 1 ? "S9" : $"S9+{overS9:0}";
    var s = 9 + overS9 / 6f;
    return s < 0.5f ? "S0" : $"S{Math.Round(s):0}";
}

// One '#' per 2 dB from -130 dBm upwards.
static string Bar(float dbm) => new('#', (int)Math.Clamp((dbm + 130) / 2, 0, 40));

static async Task<string?> ReadLineAsync(CancellationToken ct)
{
    var read = Task.Run(Console.ReadLine);
    var first = await Task.WhenAny(read, Task.Delay(Timeout.Infinite, ct));
    return first == read ? read.Result : null;
}

static void PrintUsage()
{
    Console.WriteLine("""
        tait-cli: talk to a Tait TM8100/TM8200 over its CCDI serial port.

        Usage:
          tait-cli <port> [--baud N]             open an interactive shell
          tait-cli <port> [--baud N] <command>   run one command and exit

        The port is e.g. /dev/ttyUSB0. The baud rate defaults to 28800 and must match
        what the radio's data port is programmed for. The data port must be in Command
        mode, which is its power-up state.

        """);
    PrintCommands();
}

static void PrintCommands()
{
    Console.WriteLine("""
        Commands:
          info       model, serial number, firmware and band
          version    firmware version
          channel    current channel number
          freq       current channel and band (the frequency itself is not readable)
          rssi       signal level now, in dBm and S-points
          watch [s]  keep reading the signal level every s seconds (default 0.5) until Ctrl-C
          display    text currently on the control head
          temp       power amplifier temperature
          help       this list
          quit       leave the shell
        """);
}
