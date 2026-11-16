using System.Globalization;
using System.Runtime.InteropServices;
using Minutes.Core;

namespace Minutes.App;

internal static class OutlookCalendar
{
    public static IReadOnlyList<CalendarEvent> Current(string? process,bool voice,DateTimeOffset now)
    {
        object? application=null,session=null,calendar=null,items=null,restricted=null;
        try
        {
            var hr=CLSIDFromProgID("Outlook.Application",out var clsid);if(hr<0)return [];
            hr=GetActiveObject(ref clsid,0,out application!);if(hr<0||application==null)return [];
            dynamic outlook=application;session=outlook.Session;dynamic ns=session;calendar=ns.GetDefaultFolder(9);dynamic folder=calendar;
            items=folder.Items;dynamic all=items;all.Sort("[Start]",false);all.IncludeRecurrences=true;
            string Date(DateTimeOffset date)=>date.LocalDateTime.ToString("MM/dd/yyyy hh:mm tt",CultureInfo.InvariantCulture);
            restricted=all.Restrict($"[Start] <= '{Date(now.AddMinutes(15))}' AND [End] > '{Date(now)}'");dynamic matches=restricted;
            var result=new List<CalendarEvent>();
            for(var i=1;i<=(int)matches.Count&&i<=1000;i++)
            {
                object? item=null,recipients=null;
                try
                {
                    item=matches[i];dynamic appointment=item;
                    if((int)appointment.Class!=26)continue;
                    recipients=appointment.Recipients;dynamic people=recipients;var names=new List<string>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    var mine=CurrentUserEmail(ns);var external=false;
                    var organizer=((string?)appointment.Organizer)?.Trim();if(!string.IsNullOrEmpty(organizer)&&seen.Add(organizer))names.Add(organizer);
                    for(var j=1;j<=(int)people.Count;j++)
                    {
                        object? recipient=null;
                        try
                        {
                            recipient=people[j];dynamic person=recipient;if((int)person.Type==3)continue;
                            var email=RecipientEmail(person);if(!string.IsNullOrEmpty(mine)&&string.Equals(email,mine,StringComparison.OrdinalIgnoreCase))continue;
                            var name=((string?)person.Name)?.Trim();if(string.IsNullOrEmpty(name))name=email;
                            if(!string.IsNullOrEmpty(name)&&seen.Add(name)&&(!seen.Contains(email)||email==name)){names.Add(name);if(!string.IsNullOrEmpty(email))seen.Add(email);}
                            if(External(mine,email))external=true;
                        }
                        finally{Release(recipient);}
                    }
                    result.Add(new((string?)appointment.Subject??"",new DateTimeOffset((DateTime)appointment.Start),new DateTimeOffset((DateTime)appointment.End),((string?)appointment.Body??"")+"\n"+((string?)appointment.Location??""),names.ToArray(),external,(bool)appointment.AllDayEvent,(int)appointment.MeetingStatus is 5 or 7,(int)appointment.ResponseStatus==4));
                }
                catch(COMException){}
                finally{Release(recipients);Release(item);}
            }
            return CalendarRanking.Ranked(result,now,process,voice);
        }
        catch(Exception e)when(e is COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException){return [];}
        finally{Release(restricted);Release(items);Release(calendar);Release(session);Release(application);}
    }
    private static string CurrentUserEmail(dynamic session)
    {
        object? user=null;try{user=session.CurrentUser;return RecipientEmail((dynamic)user);}catch(COMException){return "";}finally{Release(user);}
    }
    private static string RecipientEmail(dynamic person)
    {
        object? address=null,exchange=null;
        try
        {
            address=person.AddressEntry;dynamic entry=address;
            if((string?)entry.Type=="EX"){exchange=entry.GetExchangeUser();if(exchange!=null)return (string?)((dynamic)exchange).PrimarySmtpAddress??"";}
            return (string?)entry.Address??"";
        }
        catch(COMException){return "";}
        finally{Release(exchange);Release(address);}
    }
    private static bool External(string mine,string theirs)
    {
        string Domain(string email)=>email.Contains('@')?email[(email.LastIndexOf('@')+1)..].Trim().ToLowerInvariant():"";
        var a=Domain(mine);var b=Domain(theirs);return a.Length>0&&b.Length>0&&a!=b&&!a.EndsWith("."+b,StringComparison.Ordinal)&&!b.EndsWith("."+a,StringComparison.Ordinal);
    }
    private static void Release(object? value){if(value!=null&&Marshal.IsComObject(value))Marshal.ReleaseComObject(value);}
    [DllImport("ole32.dll",CharSet=CharSet.Unicode)]private static extern int CLSIDFromProgID(string progID,out Guid clsid);
    [DllImport("oleaut32.dll")]private static extern int GetActiveObject(ref Guid clsid,nint reserved,[MarshalAs(UnmanagedType.IUnknown)]out object value);
}
