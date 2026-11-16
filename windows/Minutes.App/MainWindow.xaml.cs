using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Minutes.Core;
using System.Diagnostics;
using Windows.Media.Core;
using Windows.Storage.Pickers;
using Windows.Media.SpeechSynthesis;
using Windows.Storage;

namespace Minutes.App;

public sealed partial class MainWindow : Window
{
    private AppSettings settings = AppSettings.Load();
    private Workspace workspace;
    private Meeting? selected;
    private bool loading;
    private int playerGeneration;
    private readonly System.Net.Http.HttpClient googleHttp = new() { Timeout = TimeSpan.FromMinutes(10) };
    private readonly AudioRecorder recorder = new();
    private VideoRecorder? video;
    private readonly SemaphoreSlim jobs = new(1);
    private readonly SemaphoreSlim captureActions = new(1);
    private readonly Dictionary<string, string> liveJobs = [];
    private string? recordingFolder;
    private SummaryService summaries;
    private readonly DesktopIntegration desktop;
    private readonly MeetingDetector detector = new();
    private readonly DispatcherTimer micPoll = new() { Interval = TimeSpan.FromSeconds(2) };
    private MicUser? promptedCall, recordingCall;
    private string? promptedTitle;
    private string? promptedMode;
    private string? recordingVideoError;
    private string recordingScope = "Whole-system audio";
    private ContentDialog? callDialog, stopDialog, recordingTitleDialog, consumedCallDialog;
    private Action? applyRecordingTitle;
    private bool polling;
    private readonly HashSet<string> pendingSync = [];
    private readonly DispatcherTimer syncDebounce = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly DispatcherTimer maintenance = new() { Interval = TimeSpan.FromHours(6) };
    public MainWindow()
    {
        InitializeComponent(); Title = "Minutes";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1440, 860));
        workspace = new(settings.WorkspacePath); summaries = new(AppSettings.Support, settings.FindTool);
        desktop = new(this, () => Activate(), () => { if (recorder.IsRecording) Stop_Click(this, new RoutedEventArgs()); else Record_Click(this, new RoutedEventArgs()); }, () => Stop_Click(this, new RoutedEventArgs()), () => NewNote_Click(this, new RoutedEventArgs()), () => Settings_Click(this, new RoutedEventArgs()), () => !recorder.IsRecording && jobs.CurrentCount == 1 && captureActions.CurrentCount == 1, mode => { if (recorder.IsRecording) return; settings.RecordMode = mode; promptedMode = mode; settings.Save(); RecordButton.Label = mode == "screen" ? "Record Screen" : "Record Voice"; Record_Click(this, new()); });
        Closed += (_, _) => { desktop.Dispose(); recorder.Dispose(); summaries.Dispose(); googleHttp.Dispose(); maintenance.Stop(); micPoll.Stop(); syncDebounce.Stop(); Player.MediaPlayer?.Dispose(); };
        var newNoteKey = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.N, Modifiers = Windows.System.VirtualKeyModifiers.Control }; newNoteKey.Invoked += (_, e) => { NewNote_Click(this, new()); e.Handled = true; }; ((FrameworkElement)Content).KeyboardAccelerators.Add(newNoteKey);
        RecordButton.Label = settings.RecordMode == "screen" ? "Record Screen" : "Record Voice"; Refresh(); Status.Message = "Waiting for a meeting";
        syncDebounce.Tick += async (_, _) =>
        {
            syncDebounce.Stop(); if (!await jobs.WaitAsync(0)) { syncDebounce.Start(); return; }
            try { foreach (var id in pendingSync.ToArray()) { if (workspace.Find(id) is { } meeting) await SyncMeetingAsync(meeting); pendingSync.Remove(id); } }
            catch (Exception ex) { Status.Message = "Sync needs attention: " + ex.Message; }
            finally { jobs.Release(); }
        };
        ((FrameworkElement)Content).Loaded += async (_, _) => await StartupAsync();
        maintenance.Tick += async (_, _) => await RunJob(async () => { await CleanupAsync(); await SyncAllAsync(); }, "Maintenance complete"); maintenance.Start(); micPoll.Tick += async (_, _) => await PollCallsAsync(); micPoll.Start();
    }
    private bool started;
    private async Task StartupAsync()
    {
        if (started) return; started = true;
        await RunJob(async () =>
        {
            var staging = Path.Combine(AppSettings.Support, "Recording");
            if (Directory.Exists(staging)) foreach (var folder in Directory.GetDirectories(staging))
                {
                    var meta = Workspace.ReadMeta(folder); if (meta == null) continue;
                    if (File.Exists(Path.Combine(folder, ".minutes-imported")) && workspace.Find(meta.Id) != null) { try { Directory.Delete(folder, true); } catch (IOException) { } continue; }
                    if (!Directory.GetFiles(folder).Any(f => new[] { ".wav", ".flac", ".mp4", ".mov" }.Contains(Path.GetExtension(f).ToLowerInvariant())))
                    {
                        if (Directory.GetFiles(folder).All(f => Path.GetFileName(f) == "meta.json")) Directory.Delete(folder, true);
                        continue;
                    }
                    if (!await Confirm("Recover unfinished recording?", meta.Title + " has audio left from an interrupted session.", "Recover")) continue;
                    var lastWrite = Directory.GetFiles(folder).Where(f => f.EndsWith(".wav", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase)).Select(File.GetLastWriteTimeUtc).DefaultIfEmpty(meta.StartedAt.UtcDateTime).Max();
                    await Task.Run(() => AudioRecorder.Recover(folder)); meta.EndedAt ??= new DateTimeOffset(lastWrite); Workspace.WriteMeta(folder, meta); Directory.CreateDirectory(workspace.Root);
                    var existing = meta.Note == true ? workspace.Find(meta.Id) : null;
                    if (existing != null)
                    {
                        foreach (var file in Directory.GetFiles(folder).Where(f => Path.GetFileName(f) != "meta.json")) File.Move(file, Path.Combine(existing.Folder, Path.GetFileName(file)), true);
                        workspace.Update(existing.Folder, m => { m.StartedAt = meta.StartedAt; m.EndedAt = meta.EndedAt; m.Mode = meta.Mode; m.App = meta.App; m.BundleID = meta.BundleID; m.VideoOffset = meta.VideoOffset; }); Directory.Delete(folder, true);
                    }
                    else { var target = Workspace.UniquePath(workspace.Root, Workspace.FolderName(meta.Title, meta.StartedAt)); DirectoryTransfer.Move(folder, target); }
                }
            await CleanupAsync();
            var models = new ModelStore(Path.Combine(AppSettings.Support, "models"));
            if (ModelStore.All.Where(m => settings.SeparateSpeakers || m.Transcription).Any(m => !models.Present(m))) await models.DownloadAsync(settings.SeparateSpeakers, new Progress<string>(s => Status.Message = s));
            foreach (var m in workspace.Meetings().Where(m => !Workspace.IsNote(m.Folder, m.Meta) && m.Meta.TranscriptError == null && !File.Exists(Path.Combine(m.Folder, "transcript.md")) && new[] { "me.wav", "others.wav", "me.flac", "others.flac" }.Any(n => File.Exists(Path.Combine(m.Folder, n)))))
                await new TranscriptionService(settings).TranscribeAsync(m.Folder, new Progress<string>(s => Status.Message = s));
            await SyncAllAsync();
        }, "Waiting for a meeting");
    }
    private void Refresh()
    {
        if (MeetingList == null) return; var query = Search.Text.Trim(); var group = GroupFilter.SelectedItem as MeetingGroup; var filter = Filter.SelectedIndex;
        var meetings = workspace.Meetings().ToList();
        if (recordingFolder != null && Workspace.ReadMeta(recordingFolder) is { } live)
        {
            var location = live.Note == true ? workspace.Find(live.Id)?.Folder ?? recordingFolder : recordingFolder;
            meetings.RemoveAll(m => m.Meta.Id == live.Id); meetings.Insert(0, new(location, live) { Activity = "Recording" });
        }
        MeetingList.ItemsSource = meetings.Where(m => filter == 2 ? m.Meta.ArchivedAt != null : m.Meta.ArchivedAt == null && (filter != 1 || m.Meta.PinnedAt != null))
            .Where(m => group == null || group.Id.Length == 0 || m.Meta.GroupID == group.Id).Where(m => query.Length == 0 || SearchText(m).Contains(query, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(m => m.Meta.PinnedAt).ThenByDescending(m => m.Meta.StartedAt).Select(m => m with { Activity = m.Activity ?? liveJobs.GetValueOrDefault(m.Meta.Id) }).ToArray();
        var groups = workspace.Groups(); var id = group?.Id; GroupFilter.ItemsSource = new[] { new MeetingGroup("", "All groups") }.Concat(groups).ToArray(); GroupFilter.SelectedItem = ((IEnumerable<MeetingGroup>)GroupFilter.ItemsSource).FirstOrDefault(g => g.Id == id);
    }
    private void ScheduleSync(string id) { pendingSync.Add(id); syncDebounce.Stop(); syncDebounce.Start(); }
    private static string SearchText(Meeting m) => m.Meta.Title + "\n" + string.Join("\n", new[] { "transcript.md", "notes.md", "comments.md" }.Select(n => Read(m.Folder, n)));
    private static string Read(string folder, string name) => File.Exists(Path.Combine(folder, name)) ? File.ReadAllText(Path.Combine(folder, name)) : "";
    private void Show(Meeting meeting)
    {
        loading = true; selected = meeting; MeetingTitle.IsEnabled = recordingFolder == null || meeting.Folder != recordingFolder; MeetingTitle.Text = meeting.Meta.Title; Confidential.IsChecked = meeting.Meta.Confidential == true;
        Notes.Text = Read(meeting.Folder, "notes.md"); Summary.Text = Read(meeting.Folder, "summary.md"); Transcript.Text = Read(meeting.Folder, "transcript.md"); LoadComments();
        Player.MediaPlayer?.Pause();
        var generation = ++playerGeneration;
        var video = Path.Combine(meeting.Folder, "meeting.mp4");
        Player.Source = File.Exists(video) ? MediaSource.CreateFromUri(new Uri(video)) : null; Player.Visibility = File.Exists(video) ? Visibility.Visible : Visibility.Collapsed;
        if (!File.Exists(video)) _ = PrepareAudioPlayerAsync(meeting, generation);
        loading = false;
    }
    private async Task PrepareAudioPlayerAsync(Meeting meeting, int generation)
    {
        try
        {
            var audio = await AudioPlaybackCache.PrepareAsync(meeting.Folder);
            if (generation != playerGeneration || selected?.Meta.Id != meeting.Meta.Id || recorder.IsRecording) return;
            Player.Source = audio == null ? null : MediaSource.CreateFromUri(new Uri(audio)); Player.Visibility = audio == null ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (Exception ex) { if (generation == playerGeneration) Status.Message = "Audio playback unavailable: " + ex.Message; }
    }
    private List<MeetingComment> commentList = [];
    private void LoadComments() { commentList = selected == null ? [] : CommentFiles.Read(selected.Folder); Comments.ItemsSource = commentList; }
    private void SaveComments() { if (selected == null) return; CommentFiles.Save(selected.Folder, commentList, selected.Meta.Title); ScheduleSync(selected.Meta.Id); Comments.ItemsSource = null; Comments.ItemsSource = commentList; }
    private async Task RunCaptureAction(Func<Task> work, string success)
    {
        if (!await captureActions.WaitAsync(0)) return;
        try { await work(); Status.Message = recorder.IsRecording ? "Recording · Microphone and " + recordingScope + (recordingVideoError != null ? " · Video unavailable" : "") : success; Status.Severity = InfoBarSeverity.Informational; }
        catch (Exception ex) { Status.Message = ex.Message; Status.Severity = InfoBarSeverity.Error; }
        finally { captureActions.Release(); Refresh(); }
    }
    private async Task RunJob(Func<Task> work, string success)
    {
        if (!await jobs.WaitAsync(0)) { Status.Message = "Another task is running. Wait for it to finish."; return; }
        try { Status.Severity = InfoBarSeverity.Informational; await work(); Status.Message = success; Status.Severity = recorder.IsRecording ? InfoBarSeverity.Informational : InfoBarSeverity.Success; }
        catch (Exception e) { Status.Message = e.Message; Status.Severity = InfoBarSeverity.Error; }
        finally { jobs.Release(); Refresh(); }
    }
    private async Task<string?> Ask(string title, string value = "", bool multiline = false)
    {
        var input = new TextBox { Text = value, AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, MinWidth = 380 };
        var dialog = new ContentDialog { Title = title, Content = input, PrimaryButtonText = "Save", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? input.Text : null;
    }
    private async Task<bool> Confirm(string title, string message, string action)
    {
        var d = new ContentDialog { Title = title, Content = message, PrimaryButtonText = action, CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot }; return await d.ShowAsync() == ContentDialogResult.Primary;
    }
    private void Search_Changed(object sender, TextChangedEventArgs e) => Refresh();
    private void Filter_Changed(object sender, SelectionChangedEventArgs e) { if (workspace != null) Refresh(); }
    private void Group_Changed(object sender, SelectionChangedEventArgs e) { if (!loading && workspace != null && MeetingList != null) { var id = (GroupFilter.SelectedItem as MeetingGroup)?.Id; MeetingList.ItemsSource = workspace.Meetings().Where(m => m.Meta.ArchivedAt == null && (string.IsNullOrEmpty(id) || m.Meta.GroupID == id)).ToArray(); } }
    private void Meeting_Selected(object sender, SelectionChangedEventArgs e) { if (MeetingList.SelectedItem is Meeting m) Show(m); }
    private async void NewNote_Click(object sender, RoutedEventArgs e)
    {
        var title = await Ask("New Note", "Untitled"); if (title == null) return;
        await RunJob(() => { var note = workspace.MakeNote((GroupFilter.SelectedItem as MeetingGroup)?.Id is { Length: > 0 } id ? id : null); Show(workspace.Rename(note, title)); ScheduleSync(note.Meta.Id); return Task.CompletedTask; }, "Note created");
    }
    private async void NewGroup_Click(object sender, RoutedEventArgs e)
    {
        var name = await Ask("New group"); if (string.IsNullOrWhiteSpace(name)) return; await RunJob(() => { workspace.SaveGroups(workspace.Groups().Append(new MeetingGroup(Guid.NewGuid().ToString().ToUpperInvariant(), name.Trim()))); return Task.CompletedTask; }, "Group created");
    }
    private async void Title_LostFocus(object sender, RoutedEventArgs e)
    {
        if (loading || selected == null || MeetingTitle.Text.Trim() == selected.Meta.Title) return;
        await RunJob(() => { Show(workspace.Rename(selected, MeetingTitle.Text)); ScheduleSync(selected!.Meta.Id); return Task.CompletedTask; }, "Title saved");
    }
    private void Notes_Changed(object sender, TextChangedEventArgs e)
    {
        if (loading || selected == null) return; try { JsonFiles.AtomicWrite(Path.Combine(selected.Folder, "notes.md"), Notes.Text); ScheduleSync(selected.Meta.Id); } catch (IOException ex) { Status.Message = ex.Message; Status.Severity = InfoBarSeverity.Error; }
    }
    private async void Confidential_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var meeting = selected;
        try
        {
            var meta = workspace.Update(meeting.Folder, m => { m.Confidential = Confidential.IsChecked == true; m.SentAnyway = null; });
            if (selected?.Meta.Id == meta.Id) selected = new(meeting.Folder, meta);
            if (meta.Confidential == true) await WithdrawAsync(new(meeting.Folder, meta)); Status.Message = "Confidential setting saved";
        }
        catch (Exception ex) { Status.Message = "Confidential setting saved; withdrawal needs attention: " + ex.Message; Status.Severity = InfoBarSeverity.Error; }
    }
    private async void Pin_Click(object sender, RoutedEventArgs e)
    { if (selected == null) return; await RunJob(() => { var m = workspace.Update(selected.Folder, m => { m.PinnedAt = m.PinnedAt == null ? DateTimeOffset.Now : null; if (m.PinnedAt != null) m.ArchivedAt = null; }); Show(new(selected.Folder, m)); return Task.CompletedTask; }, "Pin updated"); }
    private async void Archive_Click(object sender, RoutedEventArgs e)
    { if (selected == null) return; await RunJob(() => { var m = workspace.Update(selected.Folder, m => { m.ArchivedAt = m.ArchivedAt == null ? DateTimeOffset.Now : null; m.PinnedAt = null; }); Show(new(selected.Folder, m)); return Task.CompletedTask; }, "Archive updated"); }
    private (string Source, string Stashed, MeetingMeta Meta)? deleted;
    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null || recorder.IsRecording) return; var meeting = selected;
        if (!await Confirm("Delete this meeting?", meeting.Meta.Title + " will move to the local recovery folder. Undo can restore it.", "Delete")) return;
        await RunJob(() =>
        {
            Player.MediaPlayer?.Pause(); var stash = Path.Combine(workspace.Root, ".trash", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path.GetDirectoryName(stash)!); Directory.Move(meeting.Folder, stash); deleted = (meeting.Folder, stash, meeting.Meta); selected = null; MeetingTitle.Text = Summary.Text = Transcript.Text = Notes.Text = ""; return Task.CompletedTask;
        }, "Meeting deleted · Undo is available");
    }
    private async void UndoDelete_Click(object sender, RoutedEventArgs e)
    {
        if (deleted is not { } entry) return;
        await RunJob(() => { var target = Directory.Exists(entry.Source) ? Workspace.UniquePath(workspace.Root, Path.GetFileName(entry.Source)) : entry.Source; Directory.Move(entry.Stashed, target); deleted = null; Show(new(target, entry.Meta)); return Task.CompletedTask; }, "Meeting restored");
    }
    private async void MoveGroup_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var meeting = selected; var groups = new[] { new MeetingGroup("", "No group") }.Concat(workspace.Groups()).ToArray(); var picker = new ComboBox { ItemsSource = groups, DisplayMemberPath = "Name", SelectedItem = groups.FirstOrDefault(g => g.Id == meeting.Meta.GroupID) ?? groups[0], MinWidth = 300 };
        var dialog = new ContentDialog { Title = "Move to group", Content = picker, PrimaryButtonText = "Move", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot }; if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await RunJob(async () => { var meta = workspace.Update(meeting.Folder, m => m.GroupID = (picker.SelectedItem as MeetingGroup)?.Id is { Length: > 0 } id ? id : null); Show(new(meeting.Folder, meta)); await SyncMeetingAsync(selected!); }, "Group updated");
    }
    private async void RenameSpeaker_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var meeting = selected; var transcript = Read(meeting.Folder, "transcript.md"); var labels = Transcripts.Parse(transcript).Select(t => t.Speaker).Distinct().ToArray(); if (labels.Length == 0) return;
        var picker = new ComboBox { ItemsSource = labels, SelectedIndex = 0 }; var name = new TextBox { Header = "Name" }; var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(picker); panel.Children.Add(name);
        var dialog = new ContentDialog { Title = "Rename speaker", Content = panel, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot }; if (await dialog.ShowAsync() != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(name.Text)) return;
        await RunJob(() => { var old = picker.SelectedItem!.ToString()!; var changed = Transcripts.RenameSpeaker(transcript, old, name.Text); JsonFiles.AtomicWrite(Path.Combine(meeting.Folder, "transcript.md"), changed); Show(meeting); return Task.CompletedTask; }, "Speaker renamed");
    }
    private void WrapNote(string before, string after)
    { var start = Notes.SelectionStart; var selection = Notes.SelectedText; Notes.SelectedText = before + selection + after; Notes.Select(start + before.Length, selection.Length); Notes.Focus(FocusState.Programmatic); }
    private void Bold_Click(object sender, RoutedEventArgs e) => WrapNote("**", "**");
    private void Italic_Click(object sender, RoutedEventArgs e) => WrapNote("*", "*");
    private void Underline_Click(object sender, RoutedEventArgs e) => WrapNote("<u>", "</u>");
    private void Checklist_Click(object sender, RoutedEventArgs e) => WrapNote("- [ ] ", "");
    private async void Picture_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var meeting = selected; var picker = new FileOpenPicker(); foreach (var ext in new[] { ".png", ".jpg", ".jpeg", ".gif" }) picker.FileTypeFilter.Add(ext); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this)); var file = await picker.PickSingleFileAsync(); if (file == null) return;
        await RunJob(() => { var root = Path.Combine(meeting.Folder, "attachments"); Directory.CreateDirectory(root); var name = Path.GetFileName(file.Path); var target = Path.Combine(root, name); for (var n = 2; File.Exists(target); n++) target = Path.Combine(root, Path.GetFileNameWithoutExtension(name) + " " + n + Path.GetExtension(name)); File.Copy(file.Path, target); WrapNote("\n" + Attachments.Line(Path.GetFileName(target)) + "\n", ""); return Task.CompletedTask; }, "Picture added");
    }
    private async void Record_Click(object sender, RoutedEventArgs e)
    {
        if (recorder.IsRecording) return;
        VideoRecorder? pickedVideo = null;
        var mode = promptedCall == null ? settings.RecordMode : promptedMode ?? settings.AppModes.GetValueOrDefault(promptedCall.Owner) ?? "screen";
        if (mode == "screen")
        {
            try { pickedVideo = VideoRecorder.ForMeeting(this, promptedCall?.ProcessId, settings.VideoQuality); }
            catch (Exception ex) { if (!await Confirm("Screen could not be recorded", ex.Message + " Start Voice instead?", "Record Voice")) return; }
        }
        var note = promptedCall == null && selected != null && Workspace.IsNote(selected.Folder, selected.Meta) ? selected : null;
        var automatic = promptedCall != null;
        var calendar = automatic && settings.TitleFromCalendar ? OutlookCalendar.Current(promptedCall?.Owner, mode == "voice", DateTimeOffset.Now).FirstOrDefault() : null;
        var title = note?.Meta.Title ?? promptedTitle ?? calendar?.Title ?? (promptedCall != null ? promptedCall.AppName + " meeting" : "Meeting");
        if (calendar != null && Workspace.CleanTitle(title) != Workspace.CleanTitle(calendar.Title)) calendar = null;
        if (callDialog != null) { consumedCallDialog = callDialog; callDialog = null; consumedCallDialog.Hide(); }
        string? titleFolder = null;
        await RunCaptureAction(async () =>
        {
            Player.MediaPlayer?.Pause(); var meta = note == null ? new MeetingMeta { Title = title, Mode = pickedVideo != null ? "screen" : "voice", StartedAt = DateTimeOffset.Now } : new MeetingMeta { Id = note.Meta.Id, Title = note.Meta.Title, Note = true, GroupID = note.Meta.GroupID, Confidential = note.Meta.Confidential, Mode = pickedVideo != null ? "screen" : "voice", StartedAt = DateTimeOffset.Now };
            if (note == null) { meta.App = promptedCall?.AppName; meta.BundleID = promptedCall?.Owner; meta.Attendees = calendar?.Attendees; if (settings.ConfidentialExternal && calendar?.HasExternal == true) meta.Confidential = true; }
            promptedTitle = null; promptedMode = null; recordingVideoError = null;
            var folder = Path.Combine(AppSettings.Support, "Recording", meta.Id); if (Directory.Exists(folder)) throw new IOException("An unfinished recording with this identity exists. Recover it before recording again.");
            Directory.CreateDirectory(folder); Workspace.WriteMeta(folder, meta); var scope = await recorder.StartAsync(folder, promptedCall?.ProcessId); recordingCall = promptedCall; promptedCall = null; detector.RecordingStarted(); recordingFolder = folder; recordingScope = scope;
            titleFolder = folder; desktop.SetRecording(true); video = pickedVideo;
            if (video != null)
            {
                try { await video.StartAsync(folder, recorder.RecordingClock); meta.VideoOffset = video.Offset; Workspace.WriteMeta(folder, meta); }
                catch (Exception ex) { await video.DisposeAsync(); video = null; recordingVideoError = ex.Message; Status.Message = "Video failed; audio continues: " + ex.Message; }
            }
            Player.IsEnabled = false;
            RecordButton.IsEnabled = false; StopButton.IsEnabled = MuteButton.IsEnabled = true; Show(new(meta.Note == true ? workspace.Find(meta.Id)?.Folder ?? folder : folder, meta)); Status.Message = "Recording · Microphone and " + scope;
        }, "Recording · Microphone and whole-system audio");
        if (titleFolder != null && note == null && !automatic) _ = AskRecordingTitleAsync(titleFolder, mode);
    }
    private async Task AskRecordingTitleAsync(string folder, string mode)
    {
        var meta = Workspace.ReadMeta(folder); if (meta == null) return;
        var title = new TextBox { Header = "Title", Text = "Meeting" };
        var events = settings.TitleFromCalendar || settings.ConfidentialExternal ? OutlookCalendar.Current(null, mode == "voice", meta.StartedAt) : [];
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(title);
        var picker = new ComboBox { Header = "Calendar event", ItemsSource = events.Select(e => e.Title).Prepend("None").ToArray(), SelectedIndex = 0 }; panel.Children.Add(picker);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) }; var applied = false;
        picker.SelectionChanged += (_, _) => { title.Text = picker.SelectedIndex > 0 ? events[picker.SelectedIndex - 1].Title : "Meeting"; timer.Stop(); };
        void Apply()
        {
            if (applied) return; applied = true; var current = Directory.Exists(folder) ? folder : workspace.Find(meta.Id)?.Folder; if (current == null) return;
            var text = string.IsNullOrWhiteSpace(title.Text) ? "Meeting" : title.Text.Trim();
            var chosen = picker.SelectedIndex > 0 ? events[picker.SelectedIndex - 1] : null; if (chosen != null && Workspace.CleanTitle(text) != Workspace.CleanTitle(chosen.Title)) chosen = null;
            var changed = workspace.Update(current, m => { m.Title = text; m.Attendees = chosen?.Attendees; if (chosen != null) { m.EventPicked = true; if (settings.ConfidentialExternal && chosen.HasExternal) m.Confidential = true; } });
            if (selected?.Meta.Id == meta.Id) Show(new(current, changed)); Refresh();
        }
        var dialog = new ContentDialog { Title = "Recording", Content = panel, PrimaryButtonText = "Done", SecondaryButtonText = "Stop", XamlRoot = Content.XamlRoot }; recordingTitleDialog = dialog; applyRecordingTitle = Apply;
        timer.Tick += (_, _) => { timer.Stop(); Apply(); dialog.Hide(); }; timer.Start();
        try { var result = await dialog.ShowAsync(); Apply(); if (result == ContentDialogResult.Secondary) Stop_Click(this, new()); }
        catch (Exception ex) { Status.Message = "Recording continues: " + ex.Message; }
        finally { timer.Stop(); if (recordingTitleDialog == dialog) recordingTitleDialog = null; applyRecordingTitle = null; }
    }
    private async void Stop_Click(object sender, RoutedEventArgs e)
    {
        if (!recorder.IsRecording || recordingFolder == null) return;
        applyRecordingTitle?.Invoke(); applyRecordingTitle = null; recordingTitleDialog?.Hide(); recordingTitleDialog = null;
        string? completedFolder = null; string? failure = null;
        await RunCaptureAction(async () =>
        {
            var staged = recordingFolder; detector.StoppedByHand(recordingCall?.AppName, DateTimeOffset.Now); recordingCall = null; Status.Message = "Finishing audio…";
            string? videoFailure = recordingVideoError; recordingVideoError = null;
            if (video != null) try { await video.StopCaptureAsync(); } catch (Exception ex) { videoFailure = ex.Message; }
            await recorder.StopAsync();
            if (video != null) { try { if (videoFailure == null) await video.MuxAsync(staged); } catch (Exception ex) { videoFailure = ex.Message; } finally { await video.DisposeAsync(); video = null; } }
            desktop.SetRecording(false); Player.IsEnabled = true; var meta = Workspace.ReadMeta(staged)!; meta.EndedAt = DateTimeOffset.Now; Workspace.WriteMeta(staged, meta);
            Directory.CreateDirectory(workspace.Root); var existing = meta.Note == true ? workspace.Find(meta.Id) : null; string target;
            if (existing != null)
            {
                target = existing.Folder; foreach (var file in Directory.GetFiles(staged).Where(f => Path.GetFileName(f) != "meta.json")) File.Move(file, Path.Combine(target, Path.GetFileName(file)), true);
                var old = existing.Meta; old.StartedAt = meta.StartedAt; old.EndedAt = meta.EndedAt; old.Mode = meta.Mode; Workspace.WriteMeta(target, old); Directory.Delete(staged, true); meta = old;
            }
            else { target = Workspace.UniquePath(workspace.Root, Workspace.FolderName(meta.Title, meta.StartedAt)); DirectoryTransfer.Move(staged, target); }
            recordingFolder = null; RecordButton.IsEnabled = true; StopButton.IsEnabled = MuteButton.IsEnabled = false; MuteButton.IsChecked = false; Show(new(target, meta));
            completedFolder = target; failure = videoFailure;
        }, "Recording saved");
        if (completedFolder != null) _ = ProcessMeetingAsync(completedFolder, failure);
        else if (!recorder.IsRecording) { desktop.SetRecording(false); RecordButton.IsEnabled = true; StopButton.IsEnabled = MuteButton.IsEnabled = false; Player.IsEnabled = true; recordingFolder = null; }
    }
    private async Task ProcessMeetingAsync(string folder, string? videoFailure)
    {
        var meta = Workspace.ReadMeta(folder); if (meta == null) return; var id = meta.Id; liveJobs[id] = "Queued"; Refresh();
        await jobs.WaitAsync();
        try
        {
            liveJobs[id] = "Transcribing"; Refresh();
            await new TranscriptionService(settings).TranscribeAsync(folder, new Progress<string>(s => { if (!recorder.IsRecording) Status.Message = s; }));
            if (settings.AutoSummarise && Workspace.ReadMeta(folder)?.Confidential != true && settings.SummaryProvider != "off")
            {
                liveJobs[id] = "Summarising"; Refresh(); await SummarizeMeetingAsync(folder); folder = workspace.Find(id)?.Folder ?? folder;
                if (settings.BriefingMode == "after") await new BriefingService(settings, summaries).MakeAsync(folder, false);
            }
            await SyncMeetingAsync(new(folder, Workspace.ReadMeta(folder)!));
            if (selected?.Meta.Id == id && !recorder.IsRecording) Show(new(folder, Workspace.ReadMeta(folder)!));
            if (!recorder.IsRecording) { Status.Message = videoFailure == null ? "Transcript ready" : "Transcript ready · video unavailable: " + videoFailure; Status.Severity = videoFailure == null ? InfoBarSeverity.Success : InfoBarSeverity.Warning; }
        }
        catch (Exception ex) { Status.Message = ex.Message; Status.Severity = InfoBarSeverity.Error; }
        finally { liveJobs.Remove(id); jobs.Release(); Refresh(); }
    }
    private void Mute_Click(object sender, RoutedEventArgs e) => recorder.Mute(MuteButton.IsChecked == true);
    private SummaryModel CurrentModel() => new(settings.SummaryProvider, settings.SummaryModel);
    private async void Transcribe_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var meeting = selected; await RunJob(async () => { await new TranscriptionService(settings).TranscribeAsync(meeting.Folder, new Progress<string>(s => Status.Message = s)); Show(new(meeting.Folder, Workspace.ReadMeta(meeting.Folder)!)); }, "Transcript ready");
    }
    private async Task<string> SummarizeMeetingAsync(string folder, bool force = false)
    {
        var meta = Workspace.ReadMeta(folder) ?? throw new IOException("Meeting metadata missing");
        if (settings.SummaryPictures && File.Exists(Path.Combine(folder, "meeting.mp4")) && !File.Exists(Path.Combine(folder, "frames", "frames.json"))) await FrameExtractor.ExtractAsync(folder, new Progress<string>(s => Status.Message = s));
        var calendar = settings.TitleFromCalendar ? OutlookCalendar.Current(meta.BundleID, meta.RecordMode == "voice", meta.StartedAt) : [];
        return await summaries.SummarizeAsync(folder, CurrentModel(), settings.SummaryLanguage, settings.SummaryProvider == "off", force, workspace: workspace, calendar: calendar, confidentialExternal: settings.ConfidentialExternal);
    }
    private async void Summarise_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var meeting = selected; var force = false;
        if (meeting.Meta.Confidential == true) { force = await Confirm("Send this confidential meeting?", "The transcript and frame text will be sent to the selected summary provider for this request.", "Send for summary"); if (!force) return; }
        await RunJob(async () => { Status.Message = "Summarising…"; var summary = await SummarizeMeetingAsync(meeting.Folder, force); meeting = workspace.Find(meeting.Meta.Id) ?? meeting; Show(new(meeting.Folder, Workspace.ReadMeta(meeting.Folder)!)); if (settings.BriefingMode == "after") await new BriefingService(settings, summaries).MakeAsync(meeting.Folder, false); await SyncMeetingAsync(selected!); }, "Summary ready");
    }
    private async void Comment_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var source = Transcript.SelectionLength > 0 ? Transcript : Summary; var quote = source.SelectedText; if (quote.Length == 0) { Status.Message = "Select text in the summary or transcript first."; return; }
        var text = await Ask("Comment on “" + quote[..Math.Min(60, quote.Length)] + "”", multiline: true); if (string.IsNullOrWhiteSpace(text)) return;
        var start = source.SelectionStart; var end = start + source.SelectionLength;
        commentList.Add(new() { Target = source == Transcript ? "transcript" : "summary", Quote = quote, Prefix = source.Text[Math.Max(0, start - 32)..start], Suffix = source.Text[end..Math.Min(source.Text.Length, end + 32)], Text = text.Trim(), Author = Environment.UserName }); SaveComments();
    }
    private async void Reply_Click(object sender, RoutedEventArgs e)
    { if (Comments.SelectedItem is not MeetingComment c) return; var text = await Ask("Reply", multiline: true); if (string.IsNullOrWhiteSpace(text)) return; (c.Replies ??= []).Add(new() { Author = Environment.UserName, Text = text.Trim() }); SaveComments(); }
    private async void AskAI_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null || Comments.SelectedItem is not MeetingComment comment) return; var meeting = selected;
        await RunJob(async () =>
        {
            var meta = Workspace.ReadMeta(meeting.Folder)!;
            if (settings.SummaryProvider == "off") throw new InvalidOperationException("Summaries are off in Settings");
            if (meta.Confidential == true) throw new InvalidOperationException("Marked confidential");
            var documents = new[] { "summary.md", "transcript.md" }.Where(n => File.Exists(Path.Combine(meeting.Folder, n))).ToDictionary(n => n, n => Read(meeting.Folder, n));
            var answer = CommentRevision.Parse(await summaries.RunAsync(CurrentModel(), CommentInputs.Prompt(comment.Target), CommentInputs.Input(comment, meta.Title, documents)));
            var now = documents.Keys.ToDictionary(n => n, n => Read(meeting.Folder, n));
            var changed = CommentRevision.Apply(answer.Edits ?? [], now, comment.Target == "summary" ? "summary.md" : "transcript.md");
            var message = new CommentMessage { Author = CurrentModel().Provider switch { "claude" => "Claude", "codex" => "Codex", "agy" => "Gemini", _ => "Ollama" }, Text = string.IsNullOrWhiteSpace(answer.Reply) ? "No change." : answer.Reply.Trim(), Claude = true, Model = CurrentModel().RawValue };
            CommentRevision.Save(meeting.Folder, message, now, changed); (comment.Replies ??= []).Add(message);
            if (answer.Resolve == true && comment.ResolvedAt == null) { comment.ResolvedAt = DateTimeOffset.Now; comment.ResolvedBy = message.Author; }
            CommentFiles.Save(meeting.Folder, commentList, meta.Title); Show(new(meeting.Folder, Workspace.ReadMeta(meeting.Folder)!)); await SyncMeetingAsync(meeting);
        }, "Comment answered");
    }
    private async void UndoAI_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null || Comments.SelectedItem is not MeetingComment c) return; var reply = c.Replies?.LastOrDefault(r => r.Revised?.Count > 0 && r.Undone != true); if (reply == null) return;
        await RunJob(() => { CommentRevision.Undo(selected.Folder, reply); SaveComments(); Show(selected); return Task.CompletedTask; }, "Revision undone");
    }
    private void Resolve_Click(object sender, RoutedEventArgs e)
    { if (Comments.SelectedItem is not MeetingComment c) return; c.ResolvedAt = c.ResolvedAt == null ? DateTimeOffset.Now : null; c.ResolvedBy = c.ResolvedAt == null ? null : Environment.UserName; SaveComments(); }
    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return; var meeting = selected; var picker = new FileSavePicker { SuggestedFileName = Workspace.CleanTitle(meeting.Meta.Title) }; picker.FileTypeChoices.Add("Markdown", new List<string> { ".md" }); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this)); var file = await picker.PickSaveFileAsync(); if (file == null) return;
        await RunJob(() => { var text = Workspace.IsNote(meeting.Folder, meeting.Meta) ? "# " + meeting.Meta.Title + "\n\n" + Read(meeting.Folder, "notes.md") : string.Join("\n\n", new[] { "summary.md", "transcript.md", "notes.md", "comments.md" }.Select(n => Read(meeting.Folder, n)).Where(t => t.Length > 0)); JsonFiles.AtomicWrite(file.Path, text); return Task.CompletedTask; }, "Exported");
    }
    private void OpenFolder_Click(object sender, RoutedEventArgs e) { if (selected != null) Process.Start(new ProcessStartInfo(selected.Folder) { UseShellExecute = true }); }
    private GoogleOAuth GoogleAuth() => new(settings.GoogleClientID ?? "", new ProtectedTokenStore("google-client-secret").Read() ?? "", new ProtectedTokenStore("google-refresh-token"), googleHttp);
    private async Task SyncMeetingAsync(Meeting meeting)
    {
        if (settings.SyncMode == "folder" && settings.SyncFolder != null) await Task.Run(() => new FolderSync(workspace).CopyAsync(meeting, settings.SyncFolder, new(settings.DriveUploadText, settings.DriveUploadMedia), settings.SyncFolderPerGroup));
        else if (settings.SyncMode == "googleDrive") await new GoogleDriveSync(workspace, GoogleAuth(), googleHttp).CopyAsync(meeting, new(settings.DriveUploadText, settings.DriveUploadMedia), settings.SyncFolderPerGroup);
    }
    private async Task WithdrawAsync(Meeting meeting)
    {
        if (meeting.Meta.Sync != null) await Task.Run(() => new FolderSync(workspace).CopyAsync(meeting, settings.SyncFolder ?? ""));
        if (meeting.Meta.Drive != null) await new GoogleDriveSync(workspace, GoogleAuth(), googleHttp).WithdrawAsync(meeting);
    }
    private async Task SyncAllAsync() { foreach (var m in workspace.Meetings()) if (m.Meta.Confidential == true) await WithdrawAsync(m); else await SyncMeetingAsync(m); }
    private async void Sync_Click(object sender, RoutedEventArgs e) { if (selected != null) await RunJob(() => SyncMeetingAsync(selected), "Sync complete"); }
    private async Task CleanupAsync()
    {
        await Task.Run(() => Housekeeping.Run(workspace, DateTimeOffset.Now, new(settings.KeepVideoDays, settings.KeepAudioDays)));
    }
    private async void Capture_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null || recorder.IsRecording) return; var meeting = selected;
        await RunJob(async () => { var path = await FrameExtractor.CaptureAsync(meeting.Folder, Player.MediaPlayer?.PlaybackSession.Position.TotalSeconds ?? 0); Notes.Text += "\n![" + Transcripts.Clock(Player.MediaPlayer?.PlaybackSession.Position.TotalSeconds ?? 0) + "](" + path + ")\n"; }, "Frame added to notes");
    }
    private async void Listen_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null || recorder.IsRecording || settings.BriefingMode == "off") return; var meeting = selected;
        await RunJob(async () => { Player.MediaPlayer?.Pause(); var file = await new BriefingService(settings, summaries).MakeAsync(meeting.Folder); Player.Source = MediaSource.CreateFromUri(new Uri(file)); Player.Visibility = Visibility.Visible; Player.MediaPlayer?.Play(); }, "Playing briefing");
    }
    private async Task PollCallsAsync()
    {
        if (polling) return; polling = true;
        try
        {
            WindowCapture.Observe();
            var candidates = await Task.Run(AudioSessions.Capture); var playing = await Task.Run(AudioSessions.Playing);
            detector.AutoStopAfter = Math.Max(5, settings.AutoStopSeconds);
            var actions = detector.Poll(candidates, DateTimeOffset.Now, recorder.IsRecording ? new(recordingCall?.AppName, recordingCall != null) : null, promptedCall?.AppName, stopDialog != null,
                owner => MeetingApps.Allowed(owner, settings.AskAnyApp, settings.MeetingAppsOff, settings.MeetingAppsOn), owner => settings.AlwaysRecord.Contains(owner), outputApps: playing);
            foreach (var action in actions)
            {
                if (action.Kind == "closePrompt") { callDialog?.Hide(); promptedCall = null; }
                else if (action.Kind == "closeStopPrompt") { stopDialog?.Hide(); stopDialog = null; }
                else if (action.Kind == "stop") { stopDialog?.Hide(); stopDialog = null; Stop_Click(this, new()); }
                else if (action.Kind == "askSameCall")
                {
                    if (await Confirm("New Meeting or Same Meeting?", "The call app took the microphone again. Keep this recording for the same meeting?", "Same Meeting")) detector.KeepRecording = true;
                    else Stop_Click(this, new());
                }
                else if (action.Kind == "askToStop")
                {
                    stopDialog = new() { Title = "Stop recording?", Content = $"The meeting app released its microphone. Recording will stop after {settings.AutoStopSeconds} seconds unless you keep recording.", PrimaryButtonText = "Stop", SecondaryButtonText = "Keep Recording", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot };
                    var dialog = stopDialog;
                    _ = dialog.ShowAsync().AsTask().ContinueWith(t => DispatcherQueue.TryEnqueue(() => { if (t.Status == TaskStatus.RanToCompletion && t.Result == ContentDialogResult.Primary) Stop_Click(this, new()); else if (t.Status == TaskStatus.RanToCompletion && t.Result == ContentDialogResult.Secondary) detector.KeepRecording = true; if (stopDialog == dialog) stopDialog = null; }));
                }
                else if (action.Kind is "ask" or "recordWithoutAsking")
                {
                    promptedCall = candidates.FirstOrDefault(c => c.AppName == action.App);
                    if (promptedCall == null) continue;
                    if (action.Kind == "recordWithoutAsking") { Record_Click(this, new()); continue; }
                    var title = new TextBox { Header = "Title", Text = promptedCall.AppName + " meeting" };
                    var modes = new ComboBox { Header = "Record", ItemsSource = new[] { "screen", "voice" }, SelectedItem = settings.AppModes.GetValueOrDefault(promptedCall.Owner) ?? "screen" }; var card = new StackPanel { Spacing = 12 }; card.Children.Add(title); card.Children.Add(modes); promptedTitle = title.Text; promptedMode = modes.SelectedItem?.ToString(); title.TextChanged += (_, _) => promptedTitle = title.Text; modes.SelectionChanged += (_, _) => promptedMode = modes.SelectedItem?.ToString();
                    callDialog = new() { Title = "Record this meeting?", Content = card, PrimaryButtonText = "Record", SecondaryButtonText = "Always Record", CloseButtonText = "Not now", XamlRoot = Content.XamlRoot };
                    var app = promptedCall; var dialog = callDialog;
                    _ = dialog.ShowAsync().AsTask().ContinueWith(t => DispatcherQueue.TryEnqueue(() =>
                    {
                        if (consumedCallDialog == dialog) { consumedCallDialog = null; return; }
                        if (callDialog == dialog) callDialog = null;
                        if (t.Status != TaskStatus.RanToCompletion || t.Result == ContentDialogResult.None) { detector.Decline(app.AppName, DateTimeOffset.Now); promptedCall = null; }
                        else
                        {
                            promptedCall = app; promptedTitle = title.Text; promptedMode = modes.SelectedItem?.ToString() ?? "screen"; settings.AppModes[app.Owner] = promptedMode; settings.Save();
                            if (t.Result == ContentDialogResult.Secondary) { settings.AlwaysRecord.Add(app.Owner); settings.Save(); }
                            Record_Click(this, new());
                        }
                    }));
                }
            }
        }
        catch (Exception e) { Status.Message = "Meeting detection: " + e.Message; }
        finally { polling = false; }
    }
    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        if (recorder.IsRecording) return;
        var panel = new StackPanel { Spacing = 12, Width = 480 };
        TextBox Text(string header, string value) { var box = new TextBox { Header = header, Text = value }; panel.Children.Add(box); return box; }
        ComboBox Choice(string header, string[] values, string value) { var box = new ComboBox { Header = header, ItemsSource = values, SelectedItem = value, HorizontalAlignment = HorizontalAlignment.Stretch }; panel.Children.Add(box); return box; }
        var workspaceBox = Text("Workspace", settings.WorkspacePath);
        var provider = Choice("Summary provider", ["claude", "codex", "agy", "ollama", "off"], settings.SummaryProvider);
        var model = Text("Model (blank uses the provider default)", settings.SummaryModel);
        var toolPath = Text("CLI executable path (optional)", settings.ToolPaths.GetValueOrDefault(settings.SummaryProvider) ?? "");
        var choices = new ComboBox { Header = "Available models", ItemsSource = ModelCatalog.Models(settings.SummaryProvider), HorizontalAlignment = HorizontalAlignment.Stretch }; panel.Children.Add(choices); choices.SelectionChanged += (_, _) => { if (choices.SelectedItem is string slug) model.Text = slug; };
        var previousProvider = settings.SummaryProvider;
        provider.SelectionChanged += (_, _) =>
        {
            settings.ProviderModels[previousProvider] = model.Text;
            if (!string.IsNullOrWhiteSpace(toolPath.Text)) settings.ToolPaths[previousProvider] = toolPath.Text; else settings.ToolPaths.Remove(previousProvider);
            var current = provider.SelectedItem?.ToString() ?? "off"; previousProvider = current; choices.ItemsSource = ModelCatalog.Models(current); model.Text = settings.ProviderModels.GetValueOrDefault(current) ?? ModelCatalog.Models(current).FirstOrDefault() ?? ""; toolPath.Text = settings.ToolPaths.GetValueOrDefault(current) ?? "";
        };
        var language = Choice("Summary language", ["thai", "english", "meeting"], settings.SummaryLanguage);
        CheckBox Toggle(string label, bool value) { var control = new CheckBox { Content = label, IsChecked = value }; panel.Children.Add(control); return control; }
        var autoSummary = Toggle("Summarise after transcription", settings.AutoSummarise);
        var separate = Toggle("Separate speakers", settings.SeparateSpeakers);
        var calendarTitles = Toggle("Use calendar titles", settings.TitleFromCalendar);
        var external = Toggle("Mark external calendar meetings confidential", settings.ConfidentialExternal);
        var anyApp = Toggle("Ask to record any app using the microphone", settings.AskAnyApp);
        var mode = Choice("Default recording mode", ["screen", "voice"], settings.RecordMode);
        var quality = Choice("Video quality", ["smaller", "balanced", "best"], settings.VideoQuality);
        var speech = Choice("Spoken language", ["th", "en", "auto"], settings.SpeechLanguage);
        var signin = new Button { Content = "Sign In…" }; signin.Click += (_, _) => { try { if (provider.SelectedItem is string p) { if (!string.IsNullOrWhiteSpace(toolPath.Text)) settings.ToolPaths[p] = toolPath.Text; else settings.ToolPaths.Remove(p); } DesktopIntegration.SignIn(provider.SelectedItem?.ToString() ?? "claude", settings); } catch (Exception ex) { Status.Message = ex.Message; } }; panel.Children.Add(signin);
        var models = new Button { Content = "Download Speech Models…" }; models.Click += async (_, _) => await RunJob(() => new ModelStore(Path.Combine(AppSettings.Support, "models")).DownloadAsync(settings.SeparateSpeakers, new Progress<string>(s => Status.Message = s)), "Speech models installed"); panel.Children.Add(models);
        var briefingMode = Choice("Audio briefing", ["off", "request", "after"], settings.BriefingMode);
        var voices = SpeechSynthesizer.AllVoices.ToArray();
        var thaiVoice = new ComboBox { Header = "Thai voice", ItemsSource = voices, DisplayMemberPath = "DisplayName", SelectedItem = voices.FirstOrDefault(v => v.Id == settings.BriefingVoiceThai) ?? voices.FirstOrDefault(v => v.Language.StartsWith("th", StringComparison.OrdinalIgnoreCase)), HorizontalAlignment = HorizontalAlignment.Stretch }; panel.Children.Add(thaiVoice);
        var englishVoice = new ComboBox { Header = "English voice", ItemsSource = voices, DisplayMemberPath = "DisplayName", SelectedItem = voices.FirstOrDefault(v => v.Id == settings.BriefingVoiceEnglish) ?? voices.FirstOrDefault(v => v.Language.StartsWith("en", StringComparison.OrdinalIgnoreCase)), HorizontalAlignment = HorizontalAlignment.Stretch }; panel.Children.Add(englishVoice);
        var compress = Toggle("Compress audio losslessly after transcription", settings.CompressAudio);
        var videoDays = new NumberBox { Header = "Keep video (days; 0 means forever)", Value = settings.KeepVideoDays, Minimum = 0 }; panel.Children.Add(videoDays);
        var audioDays = new NumberBox { Header = "Keep audio after transcript (days; 0 means forever)", Value = settings.KeepAudioDays, Minimum = 0 }; panel.Children.Add(audioDays);
        var sync = Choice("Sync", ["off", "folder", "googleDrive"], settings.SyncMode);
        var googleClient = Text("Google Desktop OAuth client ID (your own)", settings.GoogleClientID ?? "");
        var googleSecret = new PasswordBox { Header = "Google Desktop OAuth client secret", Password = new ProtectedTokenStore("google-client-secret").Read() ?? "" }; panel.Children.Add(googleSecret);
        var connect = new Button { Content = "Connect Google Drive…" }; connect.Click += async (_, _) => await RunJob(async () =>
        {
            var auth = new GoogleOAuth(googleClient.Text, googleSecret.Password, new ProtectedTokenStore("google-refresh-token"), googleHttp);
            await auth.ConnectAsync(uri => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true })); settings.GoogleClientID = googleClient.Text; new ProtectedTokenStore("google-client-secret").Save(googleSecret.Password); settings.Save();
        }, "Google Drive connected"); panel.Children.Add(connect);
        var disconnect = new Button { Content = "Disconnect Google Drive" }; disconnect.Click += async (_, _) => await RunJob(() => GoogleAuth().DisconnectAsync(), "Google Drive disconnected"); panel.Children.Add(disconnect);
        var syncFolder = Text("Sync folder (Google Drive, OneDrive or Dropbox)", settings.SyncFolder ?? "");
        var uploadText = Toggle("Sync text and referenced pictures", settings.DriveUploadText);
        var uploadMedia = Toggle("Sync recording media", settings.DriveUploadMedia);
        var perGroup = Toggle("Keep a sync folder per group", settings.SyncFolderPerGroup);
        var startup = new CheckBox { Content = "Open at login", IsChecked = DesktopIntegration.IsStartupEnabled }; panel.Children.Add(startup);
        var report = BuildInfo.Report(); var about = new TextBlock { Text = report + "\n\n" + string.Join("\n\n", Changelog.Parse(Read(AppContext.BaseDirectory, "CHANGELOG.md")).Select(r => $"{r.Version}{(r.Version == "0.7.0" ? " · Current version" : "")} · {r.DateText}\n" + string.Join("\n", r.Items.Select(i => "• " + i)))), TextWrapping = TextWrapping.Wrap }; panel.Children.Add(about);
        var copyReport = new Button { Content = "Copy bug report details" }; copyReport.Click += (_, _) => { var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(report); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); }; panel.Children.Add(copyReport);
        var dialog = new ContentDialog { Title = "Settings", Content = new ScrollViewer { Content = panel }, PrimaryButtonText = "Save", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        settings.WorkspacePath = workspaceBox.Text; settings.SummaryProvider = provider.SelectedItem?.ToString() ?? "off"; settings.SummaryModel = model.Text; settings.SummaryLanguage = language.SelectedItem?.ToString() ?? "thai"; settings.SpeechLanguage = speech.SelectedItem?.ToString() ?? "auto"; settings.SyncMode = sync.SelectedItem?.ToString() ?? "off"; settings.SyncFolder = string.IsNullOrWhiteSpace(syncFolder.Text) ? null : syncFolder.Text;
        settings.ProviderModels[settings.SummaryProvider] = model.Text;
        if (!string.IsNullOrWhiteSpace(toolPath.Text)) settings.ToolPaths[settings.SummaryProvider] = toolPath.Text; else settings.ToolPaths.Remove(settings.SummaryProvider);
        settings.AutoSummarise = autoSummary.IsChecked == true; settings.SeparateSpeakers = separate.IsChecked == true; settings.TitleFromCalendar = calendarTitles.IsChecked == true; settings.ConfidentialExternal = external.IsChecked == true; settings.AskAnyApp = anyApp.IsChecked == true;
        settings.BriefingMode = briefingMode.SelectedItem?.ToString() ?? "request"; settings.BriefingVoiceThai = (thaiVoice.SelectedItem as VoiceInformation)?.Id; settings.BriefingVoiceEnglish = (englishVoice.SelectedItem as VoiceInformation)?.Id; settings.CompressAudio = compress.IsChecked == true; settings.KeepVideoDays = (int)(double.IsNaN(videoDays.Value) ? 90 : videoDays.Value); settings.KeepAudioDays = (int)(double.IsNaN(audioDays.Value) ? 0 : audioDays.Value); settings.DriveUploadText = uploadText.IsChecked == true; settings.DriveUploadMedia = uploadMedia.IsChecked == true; settings.SyncFolderPerGroup = perGroup.IsChecked == true;
        settings.VideoQuality = quality.SelectedItem?.ToString() ?? "balanced"; settings.RecordMode = mode.SelectedItem?.ToString() ?? "screen"; settings.Save(); RecordButton.Label = settings.RecordMode == "screen" ? "Record Screen" : "Record Voice"; workspace = new(settings.WorkspacePath); DesktopIntegration.SetStartup(startup.IsChecked == true); Refresh();
    }
}
