using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;

namespace FoxyVPN.Windows;

internal static class PrivateStorage
{
    public static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FoxyVPN");
    private static string Tokens => Path.Combine(Root, "credentials.dat");

    public static void CreateDirectory(string path)
    {
        Directory.CreateDirectory(path);
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        var inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        foreach (var sid in new[] { WindowsIdentity.GetCurrent().User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(acl);
    }
    public static void CleanupStaleDirectories()
    {
        CreateDirectory(Root);
        foreach (var pattern in new[] { "run-*", "login-*" })
            foreach (var path in Directory.EnumerateDirectories(Root, pattern)) Cleanup(path);
    }
    public static byte[]? LoadTokens() => File.Exists(Tokens)
        ? ProtectedData.Unprotect(File.ReadAllBytes(Tokens), null, DataProtectionScope.CurrentUser) : null;
    public static void SaveTokens(byte[] value)
    {
        CreateDirectory(Root);
        var temp = Tokens + ".tmp";
        File.WriteAllBytes(temp, ProtectedData.Protect(value, null, DataProtectionScope.CurrentUser));
        File.Move(temp, Tokens, true);
    }
    public static void DeleteTokens() { if (File.Exists(Tokens)) File.Delete(Tokens); }
    public static void Cleanup(string path) { try { Directory.Delete(path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
}
