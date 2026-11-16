using Microsoft.UI.Xaml;
using Minutes.Core;

namespace Minutes.App;
public partial class App : Application
{
    private MainWindow? window;
    public App(){InitializeComponent();}
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var arguments=Environment.GetCommandLineArgs().Skip(1).ToArray();
        if(arguments.FirstOrDefault() is "--transcribe" or "--summarize")
        {
            try
            {
                if(arguments.Length<2)throw new ArgumentException("A meeting folder is required");
                var folder=Path.GetFullPath(arguments[1]);var settings=AppSettings.Load();var meta=Workspace.ReadMeta(folder)??throw new IOException("Meeting metadata missing");
                if(!meta.IsNote)
                {
                    if(arguments[0]=="--transcribe")await new TranscriptionService(settings).TranscribeAsync(folder);
                    else
                    {
                        var modelIndex=Array.IndexOf(arguments,"--model");
                        var model=modelIndex>=0&&modelIndex+1<arguments.Length?SummaryModel.Parse(arguments[modelIndex+1]):new SummaryModel(settings.SummaryProvider,settings.SummaryModel);
                        using var service=new SummaryService(AppSettings.Support,settings.FindTool);await service.SummarizeAsync(folder,model,settings.SummaryLanguage,settings.SummaryProvider=="off");
                    }
                }
                Environment.Exit(0);
            }
            catch(Exception error)
            {
                Directory.CreateDirectory(AppSettings.Support);File.WriteAllText(Path.Combine(AppSettings.Support,"last-cli-error.txt"),error.Message);Environment.Exit(1);
            }
            return;
        }
        window=new MainWindow();window.Activate();
    }
}
