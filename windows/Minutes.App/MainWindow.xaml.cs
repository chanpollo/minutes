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
    private AppSettings settings=AppSettings.Load();
    private Workspace workspace;
    private Meeting? selected;
    private bool loading;
    private readonly AudioRecorder recorder=new();
    private VideoRecorder? video;
    private readonly SemaphoreSlim jobs=new(1);
    private string? recordingFolder;
    private SummaryService summaries;
    private readonly DesktopIntegration desktop;
    private readonly MeetingDetector detector=new();
    private readonly DispatcherTimer micPoll=new(){Interval=TimeSpan.FromSeconds(2)};
    private MicUser? promptedCall,recordingCall;
    private string? promptedTitle;
    private ContentDialog? callDialog,stopDialog;
    private bool polling;
    private readonly DispatcherTimer maintenance=new(){Interval=TimeSpan.FromHours(6)};
    public MainWindow()
    {
        InitializeComponent();Title="Minutes";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1440,860));
        workspace=new(settings.WorkspacePath);summaries=new(AppSettings.Support,settings.FindTool);
        desktop=new(this,()=>Activate(),()=>Record_Click(this,new RoutedEventArgs()),()=>Stop_Click(this,new RoutedEventArgs()),()=>NewNote_Click(this,new RoutedEventArgs()),()=>Settings_Click(this,new RoutedEventArgs()));
        Closed+=(_,_)=>{desktop.Dispose();recorder.Dispose();summaries.Dispose();maintenance.Stop();micPoll.Stop();Player.MediaPlayer?.Dispose();};
        Refresh();Status.Message="Windows preview · voice captures microphone and whole-system audio. See TESTING.md for gaps.";
        maintenance.Tick+=async(_,_)=>await RunJob(async()=>{await CleanupAsync();await SyncAllAsync();},"Maintenance complete");maintenance.Start();micPoll.Tick+=async(_,_)=>await PollCallsAsync();micPoll.Start();
    }
    private void Refresh()
    {
        if(MeetingList==null)return;var query=Search.Text.Trim();var group=GroupFilter.SelectedItem as MeetingGroup;var filter=Filter.SelectedIndex;
        MeetingList.ItemsSource=workspace.Meetings().Where(m=>filter==2?m.Meta.ArchivedAt!=null:m.Meta.ArchivedAt==null&&(filter!=1||m.Meta.PinnedAt!=null))
            .Where(m=>group==null||group.Id.Length==0||m.Meta.GroupID==group.Id).Where(m=>query.Length==0||SearchText(m).Contains(query,StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(m=>m.Meta.PinnedAt).ThenByDescending(m=>m.Meta.StartedAt).ToArray();
        var groups=workspace.Groups();var id=group?.Id;GroupFilter.ItemsSource=new[]{new MeetingGroup("","All groups")}.Concat(groups).ToArray();GroupFilter.SelectedItem=((IEnumerable<MeetingGroup>)GroupFilter.ItemsSource).FirstOrDefault(g=>g.Id==id);
    }
    private static string SearchText(Meeting m)=>m.Meta.Title+"\n"+string.Join("\n",new[]{"transcript.md","notes.md","comments.md"}.Select(n=>Read(m.Folder,n)));
    private static string Read(string folder,string name)=>File.Exists(Path.Combine(folder,name))?File.ReadAllText(Path.Combine(folder,name)):"";
    private void Show(Meeting meeting)
    {
        loading=true;selected=meeting;MeetingTitle.Text=meeting.Meta.Title;Confidential.IsChecked=meeting.Meta.Confidential==true;
        Notes.Text=Read(meeting.Folder,"notes.md");Summary.Text=Read(meeting.Folder,"summary.md");Transcript.Text=Read(meeting.Folder,"transcript.md");LoadComments();
        Player.MediaPlayer?.Pause();
        var media=new[]{"meeting.mp4","others.flac","others.wav","me.flac","me.wav"}.Select(n=>Path.Combine(meeting.Folder,n)).FirstOrDefault(File.Exists);
        Player.Source=media==null?null:MediaSource.CreateFromUri(new Uri(media));Player.Visibility=media==null?Visibility.Collapsed:Visibility.Visible;
        loading=false;
    }
    private List<MeetingComment> commentList=[];
    private void LoadComments(){commentList=selected==null?[]:File.Exists(Path.Combine(selected.Folder,"comments.json"))?JsonFiles.Read<List<MeetingComment>>(Path.Combine(selected.Folder,"comments.json"))??[]:[];Comments.ItemsSource=commentList;}
    private void SaveComments(){if(selected==null)return;CommentFiles.Save(selected.Folder,commentList,selected.Meta.Title);Comments.ItemsSource=null;Comments.ItemsSource=commentList;}
    private async Task RunJob(Func<Task> work,string success)
    {
        if(!await jobs.WaitAsync(0)){Status.Message="Another task is running. Wait for it to finish.";return;}
        try{Status.Severity=InfoBarSeverity.Informational;await work();Status.Message=success;Status.Severity=InfoBarSeverity.Success;}
        catch(Exception e){Status.Message=e.Message;Status.Severity=InfoBarSeverity.Error;}
        finally{jobs.Release();Refresh();}
    }
    private async Task<string?> Ask(string title,string value="",bool multiline=false)
    {
        var input=new TextBox{Text=value,AcceptsReturn=multiline,TextWrapping=multiline?TextWrapping.Wrap:TextWrapping.NoWrap,MinWidth=380};
        var dialog=new ContentDialog{Title=title,Content=input,PrimaryButtonText="Save",CloseButtonText="Cancel",XamlRoot=Content.XamlRoot};
        return await dialog.ShowAsync()==ContentDialogResult.Primary?input.Text:null;
    }
    private async Task<bool> Confirm(string title,string message,string action)
    {
        var d=new ContentDialog{Title=title,Content=message,PrimaryButtonText=action,CloseButtonText="Cancel",XamlRoot=Content.XamlRoot};return await d.ShowAsync()==ContentDialogResult.Primary;
    }
    private void Search_Changed(object sender,TextChangedEventArgs e)=>Refresh();
    private void Filter_Changed(object sender,SelectionChangedEventArgs e){if(workspace!=null)Refresh();}
    private void Group_Changed(object sender,SelectionChangedEventArgs e){if(!loading&&workspace!=null&&MeetingList!=null){var id=(GroupFilter.SelectedItem as MeetingGroup)?.Id;MeetingList.ItemsSource=workspace.Meetings().Where(m=>m.Meta.ArchivedAt==null&&(string.IsNullOrEmpty(id)||m.Meta.GroupID==id)).ToArray();}}
    private void Meeting_Selected(object sender,SelectionChangedEventArgs e){if(MeetingList.SelectedItem is Meeting m)Show(m);}
    private async void NewNote_Click(object sender,RoutedEventArgs e)
    {
        var title=await Ask("New Note","Untitled");if(title==null)return;
        await RunJob(()=>{var note=workspace.MakeNote((GroupFilter.SelectedItem as MeetingGroup)?.Id is {Length:>0} id?id:null);Show(workspace.Rename(note,title));return Task.CompletedTask;},"Note created");
    }
    private async void NewGroup_Click(object sender,RoutedEventArgs e)
    {
        var name=await Ask("New group");if(string.IsNullOrWhiteSpace(name))return;await RunJob(()=>{workspace.SaveGroups(workspace.Groups().Append(new MeetingGroup(Guid.NewGuid().ToString().ToUpperInvariant(),name.Trim())));return Task.CompletedTask;},"Group created");
    }
    private async void Title_LostFocus(object sender,RoutedEventArgs e)
    {
        if(loading||selected==null||MeetingTitle.Text.Trim()==selected.Meta.Title)return;
        await RunJob(()=>{Show(workspace.Rename(selected,MeetingTitle.Text));return Task.CompletedTask;},"Title saved");
    }
    private void Notes_Changed(object sender,TextChangedEventArgs e)
    {
        if(loading||selected==null)return;try{JsonFiles.AtomicWrite(Path.Combine(selected.Folder,"notes.md"),Notes.Text);}catch(IOException ex){Status.Message=ex.Message;Status.Severity=InfoBarSeverity.Error;}
    }
    private async void Confidential_Click(object sender,RoutedEventArgs e)
    {
        if(selected==null)return;await RunJob(async()=>{var meta=workspace.Update(selected.Folder,m=>{m.Confidential=Confidential.IsChecked==true;m.SentAnyway=null;});selected=new(selected.Folder,meta);if(meta.Confidential==true)await WithdrawAsync(selected);},"Confidential setting saved");
    }
    private async void Pin_Click(object sender,RoutedEventArgs e)
    {if(selected==null)return;await RunJob(()=>{var m=workspace.Update(selected.Folder,m=>{m.PinnedAt=m.PinnedAt==null?DateTimeOffset.Now:null;if(m.PinnedAt!=null)m.ArchivedAt=null;});Show(new(selected.Folder,m));return Task.CompletedTask;},"Pin updated");}
    private async void Archive_Click(object sender,RoutedEventArgs e)
    {if(selected==null)return;await RunJob(()=>{var m=workspace.Update(selected.Folder,m=>{m.ArchivedAt=m.ArchivedAt==null?DateTimeOffset.Now:null;m.PinnedAt=null;});Show(new(selected.Folder,m));return Task.CompletedTask;},"Archive updated");}
    private async void Record_Click(object sender,RoutedEventArgs e)
    {
        if(recorder.IsRecording)return;
        VideoRecorder? pickedVideo=null;
        if(settings.RecordMode=="screen")
        {
            try{pickedVideo=await VideoRecorder.PickAsync(this);if(pickedVideo==null)return;}
            catch(Exception ex){if(!await Confirm("Screen could not be recorded",ex.Message+" Start Voice instead?","Record Voice"))return;}
        }
        var note=promptedCall==null&&selected?.Meta.IsNote==true?selected:null;
        var calendar=note==null&&settings.TitleFromCalendar?OutlookCalendar.Current(promptedCall?.Owner,settings.RecordMode=="voice"&&promptedCall==null,DateTimeOffset.Now).FirstOrDefault():null;
        var title=note?.Meta.Title??promptedTitle??await Ask("Record Voice · Tell everyone you are recording.",calendar?.Title??"Meeting");if(title==null)return;
        await RunJob(async()=>
        {
            Player.MediaPlayer?.Pause();var meta=note==null?new MeetingMeta{Title=title,Mode=pickedVideo!=null?"screen":"voice",StartedAt=DateTimeOffset.Now}:new MeetingMeta{Id=note.Meta.Id,Title=note.Meta.Title,Note=true,GroupID=note.Meta.GroupID,Confidential=note.Meta.Confidential,Mode=pickedVideo!=null?"screen":"voice",StartedAt=DateTimeOffset.Now};
            if(note==null){meta.App=promptedCall?.AppName;meta.BundleID=promptedCall?.Owner;meta.Attendees=calendar?.Attendees;if(settings.ConfidentialExternal&&calendar?.HasExternal==true)meta.Confidential=true;}
            promptedTitle=null;
            var folder=Path.Combine(AppSettings.Support,"Recording",meta.Id);if(Directory.Exists(folder))throw new IOException("An unfinished recording with this identity exists. Recover it before recording again.");
            Directory.CreateDirectory(folder);Workspace.WriteMeta(folder,meta);var scope=await recorder.StartAsync(folder,promptedCall?.ProcessId);recordingCall=promptedCall;promptedCall=null;detector.RecordingStarted();recordingFolder=folder;
            video=pickedVideo;
            if(video!=null)
            {
                try{await video.StartAsync(folder,recorder.RecordingClock);meta.VideoOffset=video.Offset;Workspace.WriteMeta(folder,meta);}
                catch(Exception ex){await video.DisposeAsync();video=null;Status.Message="Video failed; audio continues: "+ex.Message;}
            }
            Player.IsEnabled=false;
            RecordButton.IsEnabled=false;StopButton.IsEnabled=MuteButton.IsEnabled=true;Status.Message="Recording · Microphone and "+scope;
        },"Recording · Microphone and whole-system audio");
    }
    private async void Stop_Click(object sender,RoutedEventArgs e)
    {
        if(!recorder.IsRecording||recordingFolder==null)return;
        await RunJob(async()=>
        {
            var staged=recordingFolder;detector.StoppedByHand(recordingCall?.AppName,DateTimeOffset.Now);recordingCall=null;Status.Message="Finishing audio…";if(video!=null)await video.StopCaptureAsync();await recorder.StopAsync();if(video!=null){try{await video.MuxAsync(staged);}finally{await video.DisposeAsync();video=null;}}Player.IsEnabled=true;var meta=Workspace.ReadMeta(staged)!;meta.EndedAt=DateTimeOffset.Now;Workspace.WriteMeta(staged,meta);
            Directory.CreateDirectory(workspace.Root);var existing=meta.Note==true?workspace.Find(meta.Id):null;string target;
            if(existing!=null)
            {
                target=existing.Folder;foreach(var file in Directory.GetFiles(staged).Where(f=>Path.GetFileName(f)!="meta.json"))File.Move(file,Path.Combine(target,Path.GetFileName(file)),true);
                var old=existing.Meta;old.StartedAt=meta.StartedAt;old.EndedAt=meta.EndedAt;old.Mode=meta.Mode;Workspace.WriteMeta(target,old);Directory.Delete(staged,true);meta=old;
            }
            else{target=Workspace.UniquePath(workspace.Root,Workspace.FolderName(meta.Title,meta.StartedAt));Directory.Move(staged,target);}
            recordingFolder=null;RecordButton.IsEnabled=true;StopButton.IsEnabled=MuteButton.IsEnabled=false;MuteButton.IsChecked=false;Show(new(target,meta));
            Status.Message="Transcribing…";await new TranscriptionService(settings).TranscribeAsync(target,new Progress<string>(s=>Status.Message=s));
            if(settings.AutoSummarise&&meta.Confidential!=true&&settings.SummaryProvider!="off")await summaries.SummarizeAsync(target,CurrentModel(),settings.SummaryLanguage);
            await SyncMeetingAsync(new(target,Workspace.ReadMeta(target)!));Show(new(target,Workspace.ReadMeta(target)!));
        },"Transcript ready");
    }
    private void Mute_Click(object sender,RoutedEventArgs e)=>recorder.Mute(MuteButton.IsChecked==true);
    private SummaryModel CurrentModel()=>new(settings.SummaryProvider,settings.SummaryModel);
    private async void Transcribe_Click(object sender,RoutedEventArgs e)
    {
        if(selected==null)return;var meeting=selected;await RunJob(async()=>{await new TranscriptionService(settings).TranscribeAsync(meeting.Folder,new Progress<string>(s=>Status.Message=s));Show(new(meeting.Folder,Workspace.ReadMeta(meeting.Folder)!));},"Transcript ready");
    }
    private async void Summarise_Click(object sender,RoutedEventArgs e)
    {
        if(selected==null)return;var meeting=selected;var force=false;
        if(meeting.Meta.Confidential==true){force=await Confirm("Send this confidential meeting?","The transcript and frame text will be sent to the selected summary provider for this request.","Send for summary");if(!force)return;}
        await RunJob(async()=>{Status.Message="Summarising…";await summaries.SummarizeAsync(meeting.Folder,CurrentModel(),settings.SummaryLanguage,settings.SummaryProvider=="off",force);Show(new(meeting.Folder,Workspace.ReadMeta(meeting.Folder)!));await SyncMeetingAsync(selected!);},"Summary ready");
    }
    private async void Comment_Click(object sender,RoutedEventArgs e)
    {
        if(selected==null)return;var source=Transcript.SelectionLength>0?Transcript:Summary;var quote=source.SelectedText;if(quote.Length==0){Status.Message="Select text in the summary or transcript first.";return;}
        var text=await Ask("Comment on “"+quote[..Math.Min(60,quote.Length)]+"”",multiline:true);if(string.IsNullOrWhiteSpace(text))return;
        var start=source.SelectionStart;var end=start+source.SelectionLength;
        commentList.Add(new(){Target=source==Transcript?"transcript":"summary",Quote=quote,Prefix=source.Text[Math.Max(0,start-32)..start],Suffix=source.Text[end..Math.Min(source.Text.Length,end+32)],Text=text.Trim(),Author=Environment.UserName});SaveComments();
    }
    private async void Reply_Click(object sender,RoutedEventArgs e)
    {if(Comments.SelectedItem is not MeetingComment c)return;var text=await Ask("Reply",multiline:true);if(string.IsNullOrWhiteSpace(text))return;(c.Replies??=[]).Add(new(){Author=Environment.UserName,Text=text.Trim()});SaveComments();}
    private void Resolve_Click(object sender,RoutedEventArgs e)
    {if(Comments.SelectedItem is not MeetingComment c)return;c.ResolvedAt=c.ResolvedAt==null?DateTimeOffset.Now:null;c.ResolvedBy=c.ResolvedAt==null?null:Environment.UserName;SaveComments();}
    private async void Export_Click(object sender,RoutedEventArgs e)
    {
        if(selected==null)return;var meeting=selected;var picker=new FileSavePicker{SuggestedFileName=Workspace.CleanTitle(meeting.Meta.Title)};picker.FileTypeChoices.Add("Markdown",new List<string>{".md"});WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));var file=await picker.PickSaveFileAsync();if(file==null)return;
        await RunJob(()=>{var text=meeting.Meta.IsNote?"# "+meeting.Meta.Title+"\n\n"+Read(meeting.Folder,"notes.md"):string.Join("\n\n",new[]{"summary.md","transcript.md","notes.md","comments.md"}.Select(n=>Read(meeting.Folder,n)).Where(t=>t.Length>0));JsonFiles.AtomicWrite(file.Path,text);return Task.CompletedTask;},"Exported");
    }
    private void OpenFolder_Click(object sender,RoutedEventArgs e){if(selected!=null)Process.Start(new ProcessStartInfo(selected.Folder){UseShellExecute=true});}
    private async Task SyncMeetingAsync(Meeting meeting)
    {if(settings.SyncMode=="folder"&&settings.SyncFolder!=null)await new FolderSync(workspace).CopyAsync(meeting,settings.SyncFolder,new(settings.DriveUploadText,settings.DriveUploadMedia),settings.SyncFolderPerGroup);}
    private async Task WithdrawAsync(Meeting meeting)
    {if(meeting.Meta.Sync!=null)await new FolderSync(workspace).CopyAsync(meeting,settings.SyncFolder??"");}
    private async Task SyncAllAsync(){foreach(var m in workspace.Meetings())if(m.Meta.Confidential==true)await WithdrawAsync(m);else await SyncMeetingAsync(m);}
    private async void Sync_Click(object sender,RoutedEventArgs e){if(selected!=null)await RunJob(()=>SyncMeetingAsync(selected),"Sync complete");}
    private async Task CleanupAsync()
    {
        await Task.Run(()=>Housekeeping.Run(workspace,DateTimeOffset.Now,new(settings.KeepVideoDays,settings.KeepAudioDays)));
    }
    private async void Listen_Click(object sender,RoutedEventArgs e)
    {
        if(selected==null||recorder.IsRecording)return;var script=Read(selected.Folder,"briefing.md");if(script.Length==0){Status.Message="No briefing.md yet. Briefing generation is pending; see PARITY.md.";return;}
        await RunJob(async()=>{Player.MediaPlayer?.Pause();using var synth=new SpeechSynthesizer();var audio=await synth.SynthesizeTextToStreamAsync(script);var player=new Windows.Media.Playback.MediaPlayer();player.Source=MediaSource.CreateFromStream(audio,audio.ContentType);Player.SetMediaPlayer(player);Player.Visibility=Visibility.Visible;player.Play();},"Playing briefing");
    }
    private async Task PollCallsAsync()
    {
        if(polling)return;polling=true;
        try
        {
            var candidates=await Task.Run(AudioSessions.Capture);var playing=await Task.Run(AudioSessions.Playing);
            detector.AutoStopAfter=Math.Max(5,settings.AutoStopSeconds);
            var actions=detector.Poll(candidates,DateTimeOffset.Now,recorder.IsRecording?new(recordingCall?.AppName,recordingCall!=null):null,promptedCall?.AppName,stopDialog!=null,
                owner=>MeetingApps.Allowed(owner,settings.AskAnyApp,settings.MeetingAppsOff,settings.MeetingAppsOn),owner=>settings.AlwaysRecord.Contains(owner),outputApps:playing);
            foreach(var action in actions)
            {
                if(action.Kind=="closePrompt"){callDialog?.Hide();promptedCall=null;}
                else if(action.Kind=="closeStopPrompt"){stopDialog?.Hide();stopDialog=null;}
                else if(action.Kind=="stop"){stopDialog?.Hide();stopDialog=null;Stop_Click(this,new());}
                else if(action.Kind=="askSameCall")
                {
                    if(await Confirm("New Meeting or Same Meeting?","The call app took the microphone again. Keep this recording for the same meeting?","Same Meeting"))detector.KeepRecording=true;
                    else Stop_Click(this,new());
                }
                else if(action.Kind=="askToStop")
                {
                    stopDialog=new(){Title="Stop recording?",Content=$"The meeting app released its microphone. Recording will stop after {settings.AutoStopSeconds} seconds unless you keep recording.",PrimaryButtonText="Stop",SecondaryButtonText="Keep Recording",CloseButtonText="Cancel",XamlRoot=Content.XamlRoot};
                    var dialog=stopDialog;
                    _=dialog.ShowAsync().AsTask().ContinueWith(t=>DispatcherQueue.TryEnqueue(()=>{if(t.Status==TaskStatus.RanToCompletion&&t.Result==ContentDialogResult.Primary)Stop_Click(this,new());else if(t.Status==TaskStatus.RanToCompletion&&t.Result==ContentDialogResult.Secondary)detector.KeepRecording=true;if(stopDialog==dialog)stopDialog=null;}));
                }
                else if(action.Kind is "ask" or "recordWithoutAsking")
                {
                    promptedCall=candidates.FirstOrDefault(c=>c.AppName==action.App);
                    if(promptedCall==null)continue;
                    if(action.Kind=="recordWithoutAsking"){Record_Click(this,new());continue;}
                    var title=new TextBox{Header="Title",Text=promptedCall.AppName+" meeting"};
                    callDialog=new(){Title="Record this meeting?",Content=title,PrimaryButtonText="Record Voice",SecondaryButtonText="Always Record",CloseButtonText="Not now",XamlRoot=Content.XamlRoot};
                    var app=promptedCall;var dialog=callDialog;
                    _=dialog.ShowAsync().AsTask().ContinueWith(t=>DispatcherQueue.TryEnqueue(()=>
                    {
                        if(callDialog==dialog)callDialog=null;
                        if(t.Status!=TaskStatus.RanToCompletion||t.Result==ContentDialogResult.None){detector.Decline(app.AppName,DateTimeOffset.Now);promptedCall=null;}
                        else
                        {
                            promptedCall=app;promptedTitle=title.Text;
                            if(t.Result==ContentDialogResult.Secondary){settings.AlwaysRecord.Add(app.Owner);settings.Save();}
                            Record_Click(this,new());
                        }
                    }));
                }
            }
        }
        catch(Exception e){Status.Message="Meeting detection: "+e.Message;}
        finally{polling=false;}
    }
    private async void Settings_Click(object sender,RoutedEventArgs e)
    {
        if(recorder.IsRecording)return;
        var panel=new StackPanel{Spacing=12,Width=480};
        TextBox Text(string header,string value){var box=new TextBox{Header=header,Text=value};panel.Children.Add(box);return box;}
        ComboBox Choice(string header,string[] values,string value){var box=new ComboBox{Header=header,ItemsSource=values,SelectedItem=value,HorizontalAlignment=HorizontalAlignment.Stretch};panel.Children.Add(box);return box;}
        var workspaceBox=Text("Workspace",settings.WorkspacePath);
        var provider=Choice("Summary provider",["claude","codex","agy","ollama","off"],settings.SummaryProvider);
        var model=Text("Model (sonnet / opus / haiku, or provider model id)",settings.SummaryModel);
        var language=Choice("Summary language",["thai","english","meeting"],settings.SummaryLanguage);
        var mode=Choice("Default recording mode",["screen","voice"],settings.RecordMode);
        var speech=Choice("Spoken language",["th","en","auto"],settings.SpeechLanguage);
        var signin=new Button{Content="Sign In…"};signin.Click+=(_,_)=>{try{DesktopIntegration.SignIn(provider.SelectedItem?.ToString()??"claude",settings);}catch(Exception ex){Status.Message=ex.Message;}};panel.Children.Add(signin);
        var models=new Button{Content="Download Speech Models…"};models.Click+=async(_,_)=>await RunJob(()=>new ModelStore(Path.Combine(AppSettings.Support,"models")).DownloadAsync(settings.SeparateSpeakers,new Progress<string>(s=>Status.Message=s)),"Speech models installed");panel.Children.Add(models);
        var sync=Choice("Sync",["off","folder"],settings.SyncMode);
        var syncFolder=Text("Sync folder (Google Drive, OneDrive or Dropbox)",settings.SyncFolder??"");
        var startup=new CheckBox{Content="Open at login",IsChecked=DesktopIntegration.IsStartupEnabled};panel.Children.Add(startup);
        var about=new TextBlock{Text="Minutes 0.7.0 · Windows preview\n"+string.Join("\n",Changelog.Parse(Read(AppContext.BaseDirectory,"CHANGELOG.md")).Take(1).SelectMany(r=>r.Items)),TextWrapping=TextWrapping.Wrap};panel.Children.Add(about);
        var dialog=new ContentDialog{Title="Settings",Content=new ScrollViewer{Content=panel},PrimaryButtonText="Save",CloseButtonText="Cancel",XamlRoot=Content.XamlRoot};
        if(await dialog.ShowAsync()!=ContentDialogResult.Primary)return;
        settings.WorkspacePath=workspaceBox.Text;settings.SummaryProvider=provider.SelectedItem?.ToString()??"off";settings.SummaryModel=model.Text;settings.SummaryLanguage=language.SelectedItem?.ToString()??"thai";settings.SpeechLanguage=speech.SelectedItem?.ToString()??"auto";settings.SyncMode=sync.SelectedItem?.ToString()??"off";settings.SyncFolder=string.IsNullOrWhiteSpace(syncFolder.Text)?null:syncFolder.Text;
        settings.RecordMode=mode.SelectedItem?.ToString()??"screen";settings.Save();workspace=new(settings.WorkspacePath);DesktopIntegration.SetStartup(startup.IsChecked==true);Refresh();
    }
}
