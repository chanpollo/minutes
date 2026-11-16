namespace Minutes.Core;

public static class DirectoryTransfer
{
    public static void Move(string source, string destination)
    {
        if (Directory.Exists(destination) || File.Exists(destination)) throw new IOException("The meeting destination already exists");
        try { Directory.Move(source, destination); }
        catch (IOException) when (Directory.Exists(source) && !Directory.Exists(destination)) { CopyThenMove(source, destination); }
    }
    public static void CopyThenMove(string source, string destination)
    {
        if (Directory.Exists(destination) || File.Exists(destination)) throw new IOException("The meeting destination already exists");
        var parent = Path.GetDirectoryName(Path.GetFullPath(destination))!; Directory.CreateDirectory(parent);
        var partial = Path.Combine(parent, ".minutes-import-" + Guid.NewGuid().ToString("N"));
        try
        {
            Copy(source, partial); Directory.Move(partial, destination);
            try { Directory.Delete(source, true); } catch (IOException) { File.WriteAllText(Path.Combine(source, ".minutes-imported"), destination); }
        }
        finally { if (Directory.Exists(partial)) Directory.Delete(partial, true); }
    }
    private static void Copy(string source, string destination)
    {
        if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0) throw new IOException("A staged recording cannot contain symbolic links");
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.GetFiles(source))
        {
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new IOException("A staged recording cannot contain symbolic links");
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        }
        foreach (var directory in Directory.GetDirectories(source)) Copy(directory, Path.Combine(destination, Path.GetFileName(directory)));
    }
}
