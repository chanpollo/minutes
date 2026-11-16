using System.Security.Cryptography;
using System.Text;
using Minutes.Core;

namespace Minutes.App;
internal sealed class ProtectedTokenStore(string name) : ITokenStore
{
    private string PathName => Path.Combine(AppSettings.Support, name + ".protected");
    public string? Read()
    {
        if (!File.Exists(PathName)) return null;
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(PathName), null, DataProtectionScope.CurrentUser)); }
        catch (CryptographicException) { return null; }
    }
    public void Save(string value)
    {
        Directory.CreateDirectory(AppSettings.Support); var part = PathName + ".partial";
        try { File.WriteAllBytes(part, ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser)); File.Move(part, PathName, true); }
        finally { if (File.Exists(part)) File.Delete(part); }
    }
    public void Delete() => File.Delete(PathName);
}
