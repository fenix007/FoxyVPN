using System.Security.Principal;

namespace FoxyVPN.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--self-test"))
        {
            try { return SelfTest.Run(); }
            catch (Exception e) { Console.Error.WriteLine(e); return 1; }
        }
        ApplicationConfiguration.Initialize();
        using var identity = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
        {
            MessageBox.Show("Запусти FoxyVPN от имени администратора для создания VPN-туннеля.", "FoxyVPN");
            return 1;
        }
        using var mutex = new Mutex(true, @"Local\FoxyVPN.Windows", out var first);
        if (!first) { MessageBox.Show("FoxyVPN уже запущен.", "FoxyVPN"); return 1; }
        try { PrivateStorage.CleanupStaleDirectories(); }
        catch (Exception e) { MessageBox.Show("Не удалось подготовить хранилище: " + e.Message, "FoxyVPN"); return 1; }
        Application.Run(new MainForm());
        return 0;
    }
}
