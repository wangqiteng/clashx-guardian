using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Guardian.Core;

namespace Guardian.Windows;

internal static class Storage
{
    public static readonly string DirectoryPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "IKuuuGuardian");
    public static string ConfigPath => Path.Combine(DirectoryPath, "settings.json");
    public static string LogPath => Path.Combine(DirectoryPath, "guardian.log");
    private static string SecretPath => Path.Combine(DirectoryPath, "controller-secret.dat");
    private static readonly object sync = new();

    public static Settings Load()
    {
        Directory.CreateDirectory(DirectoryPath);
        var settings = File.Exists(ConfigPath) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(ConfigPath)) ?? new() : new();
        settings.Validate();
        return settings;
    }

    public static string ReadSecret() => File.Exists(SecretPath)
        ? Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(SecretPath), null, DataProtectionScope.CurrentUser)) : "";

    public static void Save(Settings settings, string secret)
    {
        settings.Validate();
        Directory.CreateDirectory(DirectoryPath);
        // Controller 密钥仅使用当前 Windows 用户的 DPAPI 保存，不写入配置和诊断。
        File.WriteAllBytes(SecretPath + ".tmp", ProtectedData.Protect(Encoding.UTF8.GetBytes(secret), null, DataProtectionScope.CurrentUser));
        File.Move(SecretPath + ".tmp", SecretPath, true);
        File.WriteAllText(ConfigPath + ".tmp", JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(ConfigPath + ".tmp", ConfigPath, true);
    }

    public static void Log(string text)
    {
        lock (sync)
        {
            try
            {
                Directory.CreateDirectory(DirectoryPath);
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 1024 * 1024)
                    File.Move(LogPath, LogPath + ".1", true);
                File.AppendAllText(LogPath, $"{DateTimeOffset.Now:O} {text.Replace('\r', ' ').Replace('\n', ' ')}{Environment.NewLine}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
