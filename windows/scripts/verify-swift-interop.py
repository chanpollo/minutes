#!/usr/bin/env python3
"""Decode a .NET-generated synthetic fixture with the baseline Swift metadata declaration."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
fixture = root / "windows/Minutes.Core.Tests/bin/Debug/net8.0/interop-meta.json"
if not fixture.exists():
    raise SystemExit("Run dotnet test windows/Minutes.Core.Tests/Minutes.Core.Tests.csproj first")
workspace = (root / "Sources/Minutes/Workspace.swift").read_text()
briefing = (root / "Sources/Minutes/Briefing.swift").read_text()
meta = workspace[workspace.index("struct MeetingMeta:"):workspace.index("/// A user-made group")]
drive = workspace[workspace.index("struct DriveState:"):workspace.index("extension Notification.Name")]
info = briefing[briefing.index("struct BriefingInfo:"):briefing.index("struct BriefingError:")]
source = """import Foundation
enum RecordMode: String, Codable { case screen, voice }
struct FolderSyncState: Codable { var base: String; var path: String; var files: [String: SyncedFile] }
struct SyncedFile: Codable { var size: Int; var modified: Date }
""" + info + drive + meta + """
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let meta = try decoder.decode(MeetingMeta.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard meta.startedAt == ISO8601DateFormatter().date(from: "2026-10-30T07:00:00Z"), UUID(uuidString: meta.id) != nil else {
    fatalError("Metadata crossed the boundary incorrectly")
}
print("Baseline Swift MeetingMeta decoded .NET metadata: date and identity valid")
"""
with tempfile.TemporaryDirectory(prefix="minutes-interop-") as temporary:
    script = Path(temporary) / "verify.swift"
    script.write_text(source)
    subprocess.run(["swift", str(script), str(fixture)], check=True)
