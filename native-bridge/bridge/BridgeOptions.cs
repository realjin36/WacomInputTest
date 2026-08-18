namespace WacomNativeBridge;

internal sealed record BridgeOptions(
    string Url,
    TimeSpan? Duration,
    bool ShowWindow,
    string[] AllowedOrigins)
{
    private const string DefaultUrl = "http://127.0.0.1:8765";

    public static BridgeOptions Parse(string[] args)
    {
        var url = DefaultUrl;
        TimeSpan? duration = null;
        var showWindow = true;
        var allowedOrigins = new List<string>();

        for (var index = 0; index < args.Length; index++)
        {
            if (args[index] == "--url" && index + 1 < args.Length)
            {
                url = args[++index];
            }
            else if (args[index] == "--duration" && index + 1 < args.Length &&
                     double.TryParse(args[++index], out var seconds) && seconds > 0)
            {
                duration = TimeSpan.FromSeconds(seconds);
            }
            else if (args[index] == "--no-window")
            {
                showWindow = false;
            }
            else if (args[index] == "--allowed-origin" && index + 1 < args.Length)
            {
                allowedOrigins.Add(OriginPolicy.NormalizeAllowedOrigin(args[++index]));
            }
            else
            {
                throw new ArgumentException($"Unknown or incomplete argument: {args[index]}");
            }
        }

        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttp ||
            uri.Host is not ("127.0.0.1" or "localhost"))
        {
            throw new ArgumentException("--url must be an http://127.0.0.1 or http://localhost URL.");
        }

        return new BridgeOptions(url.TrimEnd('/'), duration, showWindow, [.. allowedOrigins]);
    }
}
