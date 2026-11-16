using System.Text;
using System.Text.RegularExpressions;

namespace Minutes.Core;
public static class Attachments
{
    public static string Line(string name)
    {
        var encoded=new StringBuilder();
        foreach(var rune in name.EnumerateRunes())
        {
            var s=rune.ToString();
            if(" %()[]<>\\".Contains(s,StringComparison.Ordinal)||System.Text.Rune.IsWhiteSpace(rune)||rune.Value<32)encoded.Append(Uri.EscapeDataString(s));else encoded.Append(s);
        }
        return "![](attachments/"+encoded+")";
    }
    public static bool Safe(string path)
    {
        var parts=path.Split('/');return parts.Length==2&&parts[0]=="attachments"&&parts[1].Length>0&&!parts[1].StartsWith('.')&&!parts[1].Contains('\\')&&!parts[1].Contains(':');
    }
    public static IReadOnlyList<string> Referenced(string markdown)=>Regex.Matches(markdown,@"\]\((attachments/[^)\s]+)\)").Select(m=>Uri.UnescapeDataString(m.Groups[1].Value)).Where(Safe).Distinct(StringComparer.Ordinal).ToArray();
}
