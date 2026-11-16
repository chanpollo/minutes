using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public record ToolOutput(int Status, string Output, string Errors)
{
    public string ErrorTail => (Errors.Length > 0 ? Errors : Output) is var text ? text[Math.Max(0, text.Length - 500)..].Trim() : "";
}
public static class ToolProcess
{
    public static string? Find(string name, string? custom = null)
    {
        if (!string.IsNullOrWhiteSpace(custom)) return File.Exists(custom) ? custom : null;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var dirs = new[] { Path.Combine(home, ".local", "bin"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"), Path.Combine(local, "Programs", name), Path.Combine(local, "Programs", "Ollama"), Path.Combine(local, "Microsoft", "WinGet", "Links"), Path.Combine(home, ".claude", "local") }
            .Concat((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator));
        var extensions = OperatingSystem.IsWindows() ? new[] { ".exe", ".cmd", ".bat", "" } : [""];
        return dirs.Where(d => d.Length > 0).SelectMany(d => extensions.Select(e => Path.Combine(d, name + e))).FirstOrDefault(File.Exists);
    }
    public static async Task<ToolOutput> RunAsync(string executable, IEnumerable<string> args, string input, string directory, TimeSpan timeout, CancellationToken cancel = default, IReadOnlyDictionary<string, string>? environment = null)
    {
        Directory.CreateDirectory(directory);
        var info = new ProcessStartInfo(executable) { WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        var arguments = args.ToArray();
        if (OperatingSystem.IsWindows() && Path.GetExtension(executable).ToLowerInvariant() is ".cmd" or ".bat")
        {
            var entry = NpmEntry(executable);
            if (entry == null) throw new IOException("Cannot resolve npm CLI shim. Set the native executable path in Settings.");
            info.FileName = Find("node") ?? throw new IOException("Node.js is required for this CLI");
            info.ArgumentList.Add(entry);
        }
        foreach (var arg in arguments) info.ArgumentList.Add(arg);
        if (environment != null) foreach (var (key, value) in environment) info.Environment[key] = value;
        using var process = new Process { StartInfo = info };
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel); deadline.CancelAfter(timeout);
        process.Start();
        using var registration = deadline.Token.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } });
        var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
        try
        {
            await process.StandardInput.WriteAsync(input.AsMemory(), deadline.Token); process.StandardInput.Close();
            await process.WaitForExitAsync(deadline.Token);
            return new(process.ExitCode, await output, await errors);
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new TimeoutException($"{Path.GetFileName(executable)} did not finish within {timeout.TotalMinutes:0} minutes"); }
    }
    public static string? NpmEntry(string shim)
    {
        var text = File.ReadAllText(shim);
        var match = Regex.Match(text, @"%dp0%[\\/]([^\r\n""]+?\.(?:mjs|cjs|js))", RegexOptions.IgnoreCase);
        if (!match.Success) return null;
        var root = Path.GetDirectoryName(Path.GetFullPath(shim))!;
        var candidate = Path.GetFullPath(Path.Combine(root, match.Groups[1].Value.Replace('\\', Path.DirectorySeparatorChar)));
        return candidate.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && File.Exists(candidate) ? candidate : null;
    }
    public static string CmdQuote(string value)
    {
        if (value.IndexOfAny(['\r', '\n', '%', '!', '"']) >= 0) throw new ArgumentException("This CLI's npm shim cannot safely receive this argument. Set its native executable path in Settings.");
        return "\"" + value + "\"";
    }
}
public record SummaryModel(string Provider, string Name)
{
    public string RawValue => Provider == "claude" ? Name : Provider + ":" + Name;
    public string Label => Provider switch { "claude" => "Claude " + System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(Name), "codex" => Name.Length == 0 ? "Codex" : Name, "agy" => Name.Length == 0 ? "Gemini" : Name, "ollama" => Name + " (Ollama)", _ => Provider };
    public TimeSpan Timeout => TimeSpan.FromSeconds(Provider switch { "claude" => 300, "codex" or "agy" => 600, _ => 1200 });
    public static SummaryModel Parse(string value)
    {
        if (value is "sonnet" or "opus" or "haiku") return new("claude", value);
        var p = value.Split(':', 2); if (p.Length != 2 || p[0] is not ("codex" or "agy" or "ollama")) throw new ArgumentException("Unknown summary model"); return new(p[0], p[1]);
    }
}
