namespace WacomNativeBridge;

internal sealed record BridgeOptions(
    string Url,
    string? WebRoot,
    TimeSpan? Duration,
    bool OpenBrowser,
    bool ShowWindow)
{
    private const string DefaultUrl = "http://127.0.0.1:8765";

    public static BridgeOptions Parse(string[] args)
    {
        var url = DefaultUrl;
        string? webRoot = null;
        TimeSpan? duration = null;
        var openBrowser = true;
        var showWindow = true;

        for (var index = 0; index < args.Length; index++)
        {
            if (args[index] == "--url" && index + 1 < args.Length)
            {
                url = args[++index];
            }
            else if (args[index] == "--web-root" && index + 1 < args.Length)
            {
                webRoot = Path.GetFullPath(args[++index]);
            }
            else if (args[index] == "--duration" && index + 1 < args.Length &&
                     double.TryParse(args[++index], out var seconds) && seconds > 0)
            {
                duration = TimeSpan.FromSeconds(seconds);
            }
            else if (args[index] == "--no-browser")
            {
                openBrowser = false;
            }
            else if (args[index] == "--no-window")
            {
                showWindow = false;
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

        return new BridgeOptions(url.TrimEnd('/'), webRoot, duration, openBrowser, showWindow);
    }
}
