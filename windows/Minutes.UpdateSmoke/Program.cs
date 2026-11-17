using Velopack;

VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
if (args.Length != 3) return 1;
try
{
    var manager = new UpdateManager(args[1]);
    if (args[0] == "verify")
    {
        if (manager.CurrentVersion?.ToString() != "1.1.0") throw new Exception("Wrong installed version after relaunch");
        if (await manager.CheckForUpdatesAsync() != null) throw new Exception("Same version offered again");
        File.WriteAllText(args[2], "Upgrade, relaunch and no-update checks passed");
        return 0;
    }
    if (manager.CurrentVersion?.ToString() != "1.0.0") throw new Exception("Wrong baseline version");
    var update = await manager.CheckForUpdatesAsync() ?? throw new Exception("No upgrade offered");
    await manager.DownloadUpdatesAsync(update);
    manager.ApplyUpdatesAndRestart(update.TargetFullRelease, ["verify", args[1], args[2]]);
    return 0;
}
catch (Exception error) { File.WriteAllText(args[2] + ".error", error.ToString()); return 2; }
