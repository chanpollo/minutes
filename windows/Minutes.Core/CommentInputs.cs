namespace Minutes.Core;
public static class CommentInputs
{
    public static string Prompt(string target)=>SummaryPrompts.Resource("revision").Replace("\\(fileName(target))",target=="summary"?"summary.md":"transcript.md",StringComparison.Ordinal);
    public static string Input(MeetingComment comment,string title,IReadOnlyDictionary<string,string> documents)
    {
        var blocks=new[]{"summary.md","transcript.md"}.Where(documents.ContainsKey).Select(name=>$"<file name=\"{name}\">\n{documents[name]}\n</file>");
        var thread=new[]{new CommentMessage{Author=comment.Author,Text=comment.Text,CreatedAt=comment.CreatedAt}}.Concat(comment.Replies??[]).Select(m=>$"<message from=\"{m.Author}\" at=\"{Transcripts.Stamp(m.CreatedAt)}\">\n{m.Text}\n</message>");
        return $"Meeting: {title}\n\n{string.Join("\n\n",blocks)}\n\nThe comment thread is on {(comment.Target=="summary"?"summary.md":"transcript.md")}, on this passage:\n<quote>{comment.Quote}</quote>\nText around it: …{comment.Prefix}[{comment.Quote}]{comment.Suffix}…\n"+(comment.LineTime is {} time?"Transcript time: "+Transcripts.Clock(time)+"\n":"")+"The thread, oldest first:\n"+string.Join("\n",thread);
    }
}
