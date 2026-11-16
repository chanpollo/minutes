namespace Minutes.Core;

public static class CommentFiles
{
    public static List<MeetingComment> Read(string folder)
    {
        var path=Path.Combine(folder,"comments.json");if(!File.Exists(path))return [];
        var comments=JsonFiles.Read<List<MeetingComment>>(path)??[];
        foreach(var c in comments)
        {
            if(c.Reply is not {} old)continue;
            var revised=old.TryGetProperty("revised",out var files)?System.Text.Json.JsonSerializer.Deserialize<Dictionary<string,string>>(files,JsonFiles.Options):null;
            if(revised==null&&old.TryGetProperty("revisedHash",out var hash))revised=new(){{c.Target=="summary"?"summary.md":"transcript.md",hash.GetString()!}};
            var reply=new CommentMessage{Id=c.Id,Author="Claude",Text=old.GetProperty("text").GetString()??"",CreatedAt=old.GetProperty("at").GetDateTimeOffset(),Claude=true,Model=old.GetProperty("model").GetString(),Revised=old.TryGetProperty("changed",out var changed)&&changed.GetBoolean()?revised:null,Undone=old.TryGetProperty("undone",out var undone)?undone.GetBoolean():null};
            c.Replies=[reply,..c.Replies??[]];c.Reply=null;
        }
        return comments;
    }
    public static void Save(string folder,IReadOnlyList<MeetingComment> comments,string title)
    {
        JsonFiles.Write(Path.Combine(folder,"comments.json"),comments);
        JsonFiles.AtomicWrite(Path.Combine(folder,"comments.md"),Markdown(comments,title));
    }
    public static string Markdown(IReadOnlyList<MeetingComment> comments,string title)
    {
        var parts=new List<string>{"# Comments · "+title};
        foreach(var (target,heading) in new[]{("summary","On the summary"),("transcript","On the transcript"),("resolved","Resolved")})
        {
            var list=comments.Where(c=>target=="resolved"?c.ResolvedAt!=null:c.ResolvedAt==null&&c.Target==target).OrderBy(c=>c.CreatedAt).ToArray();if(list.Length==0)continue;
            parts.Add("## "+heading);
            foreach(var c in list)
            {
                var quote=(c.LineTime is {} time?"["+Transcripts.Clock(time)+"] ":"")+c.Quote;
                var entry=string.Join("\n",quote.Split('\n').Select(l=>"> "+l))+"\n\n"+c.Text+"\n\n*"+c.Author+" · "+Transcripts.Stamp(c.CreatedAt)+(c.EditedAt!=null?" (edited)":"")+"*";
                foreach(var reply in c.Replies??[])entry+="\n\n"+reply.Text+"\n\n*"+reply.Author+" · "+Transcripts.Stamp(reply.CreatedAt)+(reply.Undone==true?" (undone)":reply.EditedAt!=null?" (edited)":"")+"*";
                if(c.ResolvedAt is {} date)entry+="\n\n*Resolved by "+(c.ResolvedBy??"someone")+" · "+Transcripts.Stamp(date)+"*";
                parts.Add(entry);
            }
        }
        return string.Join("\n\n",parts)+"\n";
    }
}
