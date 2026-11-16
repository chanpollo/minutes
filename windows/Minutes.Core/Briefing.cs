using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public static class Briefing
{
    public static string Language(string text)
    {
        var thai=text.Count(c=>c is >= '\u0e01' and <= '\u0e5b');var latin=text.Count(c=>c<=127&&char.IsLetter(c));return thai>0&&thai>=.25*(thai+latin)?"thai":"english";
    }
    public static string Hash(string text)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
    public static string SummaryBody(string summary)
    {
        var rows=Regex.Split(summary,@"\r\n|\r|\n").ToList();if(rows.FirstOrDefault()?.StartsWith("# ",StringComparison.Ordinal)==true)rows.RemoveAt(0);
        while(rows.Count>0&&(rows[0].Trim().Length==0||rows[0].Contains(" · Summarised by ",StringComparison.Ordinal)))rows.RemoveAt(0);
        return string.Join("\n",rows.Where(l=>!Regex.IsMatch(l.Trim(),@"^!\[[^\]]*\]\(frames/[^)]+\)$"))).Trim();
    }
    public static string[] SplitSentences(string line)=>Regex.Replace(line,"(?<=[.!?])\\s+(?=[A-Z\"“'])","\n").Split('\n').Select(l=>l.Trim()).Where(l=>l.Length>0).ToArray();
    public static string Clean(string reply)
    {
        var output=new List<string>();
        foreach(var raw in Regex.Split(reply,@"\r\n|\r|\n"))
        {
            var line=raw.Trim();if(line.StartsWith('|')||line.Length>0&&line.All(c=>"-*_= ".Contains(c)))continue;
            line=Regex.Replace(line,@"^(#+|[-*•]|\d+[.)])\s+","").Replace("**","",StringComparison.Ordinal).Replace("__","",StringComparison.Ordinal).Replace("`","",StringComparison.Ordinal);
            if(line.Length==0)output.Add("");else output.AddRange(SplitSentences(line));
        }
        return Regex.Replace(string.Join("\n",output),@"\n{3,}","\n\n").Trim();
    }
    public static IReadOnlyList<string[]> Parse(string text)=>Regex.Split(text.Trim(),@"\r?\n\s*\r?\n").Select(p=>p.Split('\n').Select(l=>l.Trim()).Where(l=>l.Length>0).ToArray()).Where(p=>p.Length>0).ToArray();
    public static string Plain(string text)=>Regex.Replace(Regex.Replace(text,@"\[(\d{1,2}:)?\d{1,2}:\d{2}\]",""),@"\[([^\]]*)\]\([^)]*\)","$1").Replace("**","",StringComparison.Ordinal).Replace("`","",StringComparison.Ordinal).Replace("<u>","",StringComparison.Ordinal).Replace("</u>","",StringComparison.Ordinal).Trim();
    public static string Input(MeetingMeta meta,string body)
    {
        var lines=new List<string>{"Meeting: "+meta.Title,"Date: "+meta.StartedAt.LocalDateTime.ToString("dddd d MMMM yyyy",CultureInfo.InvariantCulture),"Time: "+meta.StartedAt.LocalDateTime.ToString("HH:mm",CultureInfo.InvariantCulture)+(meta.EndedAt is {} end?"–"+end.LocalDateTime.ToString("HH:mm",CultureInfo.InvariantCulture):"")};
        if(!string.IsNullOrEmpty(meta.App))lines.Add("App: "+meta.App);if(meta.Attendees?.Length>0)lines.Add("Invited: "+string.Join(", ",meta.Attendees));return string.Join("\n",lines)+"\n\n"+body;
    }
    public static string LocalScript(MeetingMeta meta,string body,string language)
    {
        var sections=Regex.Split(body,@"(?m)^## [^\r\n]+\r?\n").Skip(1).ToArray();var about=sections.ElementAtOrDefault(0)??body;var decisions=sections.ElementAtOrDefault(1)??"";var actions=sections.ElementAtOrDefault(2)??"";
        var none=new HashSet<string>{"ไม่มี","None","ไม่ระบุ","Not stated","-","—",""};
        var aboutLines=about.Split('\n').Select(Plain).Where(t=>!none.Contains(t)).ToArray();
        var decisionLines=decisions.Split('\n').Select(l=>Plain(Regex.Replace(l.Trim(),@"^[-*]\s+",""))).Where(t=>!none.Contains(t)).ToArray();
        var actionRows=actions.Split('\n').Where(l=>l.TrimStart().StartsWith('|')).Select(l=>l.Trim().Trim('|').Split('|').Select(Plain).ToArray()).Skip(2).Where(r=>r.Length>0&&!none.Contains(r[0])).ToArray();
        var output=new List<string>();var date=meta.StartedAt.LocalDateTime;var end=meta.EndedAt?.LocalDateTime;
        if(language=="thai")
        {
            var opening=$"สรุปประชุม {meta.Title} ค่ะ\nประชุมเมื่อ{ThaiSpeech.Date(date)} ตั้งแต่{ThaiSpeech.Time(date.Hour,date.Minute)}"+(end is {} e?"ถึง"+ThaiSpeech.Time(e.Hour,e.Minute):"")+(!string.IsNullOrEmpty(meta.App)?" ทาง "+meta.App:"");
            if(meta.Attendees?.Length>0)opening+="\nผู้เข้าร่วมมีคุณ "+string.Join(" และ",meta.Attendees)+"ค่ะ";output.Add(opening);
            if(aboutLines.Length>0)output.Add(string.Join("\n",aboutLines));
            if(decisionLines.Length>0)output.Add("ที่ประชุมตัดสินใจ"+ThaiSpeech.Number(decisionLines.Length)+"เรื่องค่ะ\n"+string.Join("\n",decisionLines.Select((d,i)=>(i==0?"เรื่องแรก":"เรื่องที่"+ThaiSpeech.Number(i+1))+" "+d)));
            if(actionRows.Length>0)output.Add("งานที่ต้องตามมี"+ThaiSpeech.Number(actionRows.Length)+"เรื่องค่ะ\n"+string.Join("\n",actionRows.Select(r=>(r.Length>1&&!none.Contains(r[1])?(r[1]=="Me"?"คุณ ":"คุณ"+r[1]+" "):"")+r[0]+(r.Length>2&&!none.Contains(r[2])?" ภายใน"+r[2]:""))));output.Add("จบสรุปค่ะ");
        }
        else
        {
            var opening=$"Here's your briefing on {meta.Title}.\nIt was on {date.ToString("dddd, MMMM d",CultureInfo.InvariantCulture)}, from {date.ToString(date.Minute==0?"h tt":"h:mm tt",CultureInfo.InvariantCulture)}"+(end is {} e?" to "+e.ToString(e.Minute==0?"h tt":"h:mm tt",CultureInfo.InvariantCulture):"")+(!string.IsNullOrEmpty(meta.App)?", on "+meta.App:"")+".";
            if(meta.Attendees?.Length>0)opening+="\nYou were there with "+(meta.Attendees.Length==1?meta.Attendees[0]:string.Join(", ",meta.Attendees.SkipLast(1))+" and "+meta.Attendees[^1])+".";output.Add(opening);
            if(aboutLines.Length>0)output.Add(string.Join("\n",aboutLines.SelectMany(SplitSentences)));
            if(decisionLines.Length>0)output.Add((decisionLines.Length==1?"One thing was decided.":Count(decisionLines.Length)+" things were decided.")+"\n"+string.Join("\n",decisionLines.Select((d,i)=>new[]{"First","Second","Third","Fourth","Fifth","Sixth","Seventh","Eighth","Ninth","Tenth"}.ElementAtOrDefault(i)+", "+d)));
            if(actionRows.Length>0)output.Add((actionRows.Length==1?"There is one action item.":"There are "+Count(actionRows.Length).ToLowerInvariant()+" action items.")+"\n"+string.Join("\n",actionRows.Select(r=>(r.Length>1&&!none.Contains(r[1])?(r[1]=="Me"?"You: ":r[1]+": "):"")+r[0]+(r.Length>2&&!none.Contains(r[2])?", by "+r[2]:"")+".")));output.Add("That's the briefing.");
        }
        return string.Join("\n\n",output);
    }
    private static string Count(int n)=>new[]{"Zero","One","Two","Three","Four","Five","Six","Seven","Eight","Nine","Ten"}.ElementAtOrDefault(n)??n.ToString(CultureInfo.InvariantCulture);
}
public static class ThaiSpeech
{
    private static readonly string[] Digits=["ศูนย์","หนึ่ง","สอง","สาม","สี่","ห้า","หก","เจ็ด","แปด","เก้า"];
    private static readonly string[] Places=["","สิบ","ร้อย","พัน","หมื่น","แสน"];
    public static string Number(int n)
    {
        if(n<=0)return n==0?Digits[0]:"ลบ"+Number(-n);if(n>=1000000)return Number(n/1000000)+"ล้าน"+(n%1000000>0?Number(n%1000000):"");
        var digits=n.ToString(CultureInfo.InvariantCulture);var result="";
        for(var i=0;i<digits.Length;i++)
        {
            var digit=digits[i]-'0';if(digit==0)continue;var place=digits.Length-1-i;
            result+=(place,digit) switch{(0,1)when n>9=>"เอ็ด",(1,1)=>"สิบ",(1,2)=>"ยี่สิบ",_=>Digits[digit]+Places[place]};
        }
        return result;
    }
    public static string Date(DateTime d)=>"วัน"+new[]{"อาทิตย์","จันทร์","อังคาร","พุธ","พฤหัสบดี","ศุกร์","เสาร์"}[(int)d.DayOfWeek]+"ที่"+Number(d.Day)+new[]{"มกราคม","กุมภาพันธ์","มีนาคม","เมษายน","พฤษภาคม","มิถุนายน","กรกฎาคม","สิงหาคม","กันยายน","ตุลาคม","พฤศจิกายน","ธันวาคม"}[d.Month-1];
    public static string Time(int hour,int minute)
    {
        var text=hour switch{0=>"เที่ยงคืน",>=1 and <=5=>"ตี"+Number(hour),>=6 and <=11=>Number(hour)+"โมงเช้า",12=>"เที่ยง",13=>"บ่ายโมง",>=14 and <=15=>"บ่าย"+Number(hour-12)+"โมง",>=16 and <=18=>Number(hour-12)+"โมงเย็น",_=>Number(hour-18)+"ทุ่ม"};
        return text+(minute==0?"":minute==30?"ครึ่ง":Number(minute)+"นาที");
    }
}
