using System.Diagnostics;

namespace WacomLocalBridge;

internal static class Program
{
    [STAThread]
    private static async Task<int> Main(string[] args)
    {
        BridgeOptions options;
        try
        {
            options = BridgeOptions.Parse(args);
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 64;
        }

        using var shutdown = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };

        await using var runtime = new BridgeRuntime(options);
        runtime.Started += () =>
        {
            if (options.OpenBrowser)
            {
                OpenChrome(options.Url);
            }
        };
        return await runtime.RunAsync(shutdown.Token);
    }

    // Kept unchanged for the lifecycle refactor. Stage 4 replaces this with
    // the Windows default-browser launch path shared by startup and the GUI.
    private static void OpenChrome(string url)
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Google", "Chrome", "Application", "chrome.exe")
        };

        var chrome = candidates.FirstOrDefault(File.Exists);
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = chrome ?? url,
                Arguments = chrome is null ? "" : url,
                UseShellExecute = true
            });
        }
        catch (Exception exception)
        {
            Console.WriteLine($"Chrome 자동 실행 실패: {exception.Message}");
            Console.WriteLine($"직접 접속: {url}");
        }
    }
}
