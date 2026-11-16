using Minutes.Core;
using System.Globalization;

namespace Minutes.App;
public sealed class AppSettings
{
    public static string Support => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Minutes");
    private static string FileName => Path.Combine(Support, "settings.json");
    public string WorkspacePath { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Meetings");
    public Dictionary<string, string> AppModes { get; set; } = [];
    public string RecordMode { get; set; } = "screen";
    public string SpeechLanguage { get; set; } = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "th" ? "th" : "auto";
    public string SummaryProvider { get; set; } = "claude";
    public Dictionary<string, string> ProviderModels { get; set; } = [];
    public string SummaryModel { get; set; } = "sonnet";
    public string BriefingMode { get; set; } = "request";
    public string? BriefingVoiceThai { get; set; }
    public string? BriefingVoiceEnglish { get; set; }
    public int BriefingRate { get; set; } = 2;
    public string SummaryLanguage { get; set; } = "thai";
    public bool AskAnyApp { get; set; }
    public HashSet<string> MeetingAppsOff { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public HashSet<string> MeetingAppsOn { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public HashSet<string> AlwaysRecord { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public int AutoStopSeconds { get; set; } = 30;
    public bool SummaryPictures { get; set; } = true;
    public bool AutoSummarise { get; set; }
    public bool SeparateSpeakers { get; set; } = true;
    public bool CompressAudio { get; set; } = true;
    public bool TitleFromCalendar { get; set; } = true;
    public bool ConfidentialExternal { get; set; } = true;
    public int KeepVideoDays { get; set; } = 90;
    public int KeepAudioDays { get; set; }
    public bool DeleteOnDrive { get; set; }
    public string SyncMode { get; set; } = "off";
    public string? GoogleClientID { get; set; }
    public string? SyncFolder { get; set; }
    public bool DriveUploadText { get; set; } = true;
    public bool DriveUploadMedia { get; set; } = true;
    public bool SyncFolderPerGroup { get; set; } = true;
    public Dictionary<string, string> ToolPaths { get; set; } = [];
    public static AppSettings Load() { try { return JsonFiles.Read<AppSettings>(FileName) ?? new(); } catch (Exception e) when (e is IOException or System.Text.Json.JsonException) { return new(); } }
    public void Save() => JsonFiles.Write(FileName, this);
    public string? FindTool(string name) => ToolProcess.Find(name, ToolPaths.GetValueOrDefault(name));
}
