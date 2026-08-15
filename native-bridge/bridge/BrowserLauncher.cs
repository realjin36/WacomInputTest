using System.Diagnostics;

namespace WacomLocalBridge;

internal static class BrowserLauncher
{
    public static bool OpenDefault(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true
            });
            return true;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"기본 브라우저 실행 실패: {exception.Message}");
            Console.Error.WriteLine($"직접 접속: {url}");
            return false;
        }
    }
}
