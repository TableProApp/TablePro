using System.Security.Cryptography;
using System.Text;

namespace TablePro.App.Model;

// Hashed, so a folder of any length or spelling gives a short key of plain characters.
public static class InstanceKey
{
    public static string For(string dataFolder)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataFolder);
        // Windows names one folder in any case, with or without a trailing separator.
        var folder = dataFolder.TrimEnd('\\', '/').ToUpperInvariant();
        return "TablePro-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(folder)));
    }
}
