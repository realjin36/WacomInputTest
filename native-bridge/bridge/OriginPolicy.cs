namespace WacomNativeBridge;

internal sealed class OriginPolicy
{
    private readonly HashSet<string> _allowedOrigins;

    public OriginPolicy(IEnumerable<string> allowedOrigins)
    {
        _allowedOrigins = new HashSet<string>(allowedOrigins, StringComparer.OrdinalIgnoreCase);
    }

    public bool IsAllowed(string? origin)
    {
        if (string.IsNullOrEmpty(origin))
        {
            return true;
        }

        return TryNormalize(origin, out var normalized, out var host) &&
               (IsLoopbackHost(host) || _allowedOrigins.Contains(normalized));
    }

    public static string NormalizeAllowedOrigin(string origin)
    {
        if (!TryNormalize(origin, out var normalized, out _))
        {
            throw new ArgumentException(
                "--allowed-origin must be an HTTP or HTTPS origin without a path, query, or fragment.");
        }
        return normalized;
    }

    private static bool TryNormalize(string origin, out string normalized, out string host)
    {
        normalized = string.Empty;
        host = string.Empty;
        if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            uri.AbsolutePath != "/" ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            return false;
        }

        host = uri.Host.Trim('[', ']');
        if (string.IsNullOrEmpty(host))
        {
            return false;
        }

        normalized = uri.GetLeftPart(UriPartial.Authority).TrimEnd('/');
        return true;
    }

    private static bool IsLoopbackHost(string host) =>
        host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
        host == "127.0.0.1" ||
        host == "::1";
}
