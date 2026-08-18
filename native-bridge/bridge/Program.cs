using System.Windows.Forms;

namespace WacomNativeBridge;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
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

        return options.ShowWindow
            ? RunWithWindow(options)
            : RunHeadlessAsync(options).GetAwaiter().GetResult();
    }

    private static int RunWithWindow(BridgeOptions options)
    {
        ApplicationConfiguration.Initialize();

        var runtime = new BridgeRuntime(options);
        using var window = new BridgeStatusForm(runtime);
        var runtimeTask = runtime.RunAsync();
        window.AttachRuntimeTask(runtimeTask);

        Application.Run(window);
        runtime.RequestStop();
        var exitCode = runtimeTask.GetAwaiter().GetResult();
        runtime.DisposeAsync().AsTask().GetAwaiter().GetResult();
        return exitCode;
    }

    private static async Task<int> RunHeadlessAsync(BridgeOptions options)
    {
        using var shutdown = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };

        await using var runtime = new BridgeRuntime(options);
        return await runtime.RunAsync(shutdown.Token);
    }
}
