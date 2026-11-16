# Windows parity with Minutes 0.7.0

Windows release version: **1.0.0** (owner-selected). Mac behavior baseline: main `7dd649b` (0.7.0). This is a work in progress, **not a full-parity release**. A CI build proves compilation and portable tests; it cannot prove audio, capture, sign-in or UI behavior. No feature has been exercised on a real Windows PC yet.

State vocabulary: **built** = implementation exists; **CI tested** = exercised by automated tests; **PC required** = Windows hardware/integration verification outstanding; **pending** = implementation incomplete or absent. A row can have more than one state.

| Mac feature / source | Windows approach | State |
|---|---|---|
| Workspace, ISO-8601 meta, groups, modes and legacy call/inPerson (`Workspace`, `RecordModes`) | Portable .NET core; preserve unknown meta fields, Drive/sync/briefing objects | Built; portable logic CI tested; latest additions require the linked CI check to pass |
| Folder names, collision suffixes, retitle only original headers | Same date/title layout; Windows-invalid characters also replaced; trailing dots removed | Built; portable logic CI tested; latest additions require the linked CI check to pass |
| New Note, write notes.md, record into open note without changing identity | WinUI plain text Markdown editor, notes-first storage | Built; PC required; rich text parity pending |
| Search titles, transcripts, notes, comments | In-memory, case-insensitive | Built; PC required |
| Pin, archive, groups | Native controls, JSON metadata | Built; PC required; group move and local delete/undo built; drag/reorder and swipe pending |
| Screen / Voice entry points, app defaults | Default mode, explicit Screen/Voice tray entries, mode on Record? card | Screen/Voice and per-app defaults built; PC required |
| Window video, newest 320×200 window or display (`ScreenRecorder`, `Muxer`) | Windows.Graphics.Capture → Media Foundation H.264 → mixed AAC meeting.mp4 | Window selection by most recently observed eligible HWND and monitor fallback built and compiled on CI; PC required |
| Mic + call track, common clock, mute (`Recording`, `AudioTracks`) | NAudio WASAPI mic and whole-system loopback, clock padding, 16 kHz mono PCM | Fallback and process loopback built/compiled on CI; microphone uses communications AEC only on loudspeaker routes that advertise it, raw mode otherwise; PC effect validation required |
| Process loopback | ActivateAudioInterfaceAsync PROCESS_LOOPBACK, process tree inclusion | Built and compiled on CI; PC required; requires build 20348+, unlike the proposed 19041/2004 minimum. Older PCs need whole-system fallback |
| Meeting app allow list, remembered apps, Always Record (`MeetingApps`, `MicMonitor`) | Capture/render audio-session and process enumeration | Built and compiled on CI; PC required; helper ownership and remembered-app settings pending |
| Record? / Stop? cards, 2 polls, 3 s prompt, 30 s stop, Keep Recording, Same/New Meeting (`MeetingDetector`) | Portable state machine plus WinUI dialogs | Built; state machine CI tested; PC required; per-app/default modes built; new-meeting handoff incomplete |
| Local speech models (`ModelStore`) | Same four URLs, byte sizes, archive/member SHA-256; LocalAppData/Minutes/models; atomic install | Built; HTTP Range resume and checksum checks tested; PC download required |
| whisper.cpp bundled CLI | Build pinned whisper.cpp on Windows CI, ship exe and DLLs in tools/ | Built and bundled on green CI |
| sherpa-onnx CLI and 0.65 threshold | Bundle Windows x64 binary; same CLI args; nearest-segment absorption | Post-processing built/tested locally; binary bundled on green CI |
| Language th/en/auto, Thai UTF-8 token reconstruction (`Transcriber`) | Pure C# parser; punctuation, pause, voice edges, Thai joins and global labels | Built; portable logic CI tested; latest additions require the linked CI check to pass |
| Repetition, fillers p<0.5, two-minute recurrence, trigram dedupe (`TranscriptCleaner`) | Pure C# rules and thresholds | Built; portable logic CI tested; latest additions require the linked CI check to pass |
| Second whisper pass (-mc 0), measured-leak gate, FLAC sample-exact verification | 100 ms log envelopes, ±1 s lag, 0.2 leak gate; second whisper pass; pinned FLAC CLI with decode/sample comparison | Built; pure leak metric tested; PC speech/compression verification required |
| Rename speakers in transcript | Preserve exact turn markers, change labels only, refresh comments export | Built; portable tests; PC required |
| Summary Claude, Codex, agy, Ollama (`SummaryEngines`, `Summarizer`) | Same arguments, timeouts, prompts; CLI process stdin; isolated working directory | Built; PC provider verification required; npm shim resolved through Node entrypoint; tested locally |
| Summary Off / confidential explicit send / auto summary | Service guards; explicit send dialog; settings stored locally | Built; local prompt tests; PC required |
| Summary languages, event choice and known picture filtering | Pure C# prompt composition and post-processing | Built; local tests; calendar re-selection orchestration built; PC required |
| Own Ollama process | Only 127.0.0.1:21434; never start or use 11434 (explicit owner requirement overrides Mac reuse) | Built; PC required |
| Sign In… (`SettingsModel.signIn`) | Windows Terminal or cmd: claude auth login / codex login / agy | Built; PC required |
| Model discovery, auth checks, provider menus | Codex cache and Ollama manifests; model entry and custom CLI path | Built; agy model refresh and proactive sign-in checks pending |
| Calendar title, invitees, overlap, external confidentiality (`CalendarTitle`) | Practical initial plan: classic Outlook COM, no app registration; Microsoft 365 Graph for new Outlook needs user-supplied app id/consent | Ranking CI tested; classic Outlook COM compiled on CI; PC required; Graph adapter pending |
| Frames, stillness grid, OCR th/en, Capture (`Frames`) | Windows.Media.Ocr; same frames/ JSON and JPEG names; brightness-grid selection in core | Frame selection and OCR/Capture built; local tests; CI compiled; PC required |
| Notes formatting, attachments, Markdown roundtrip (`NotesMarkdown`, `NotesPictures`) | Plain Markdown saved unchanged; planned rich editor mapping | Plain Markdown editor, B/I/U/checklist actions and image file picker built; WYSIWYG, clipboard/drop and exact rich-text roundtrip pending |
| Comments quote/context/time anchors (`Comments`) | Same JSON records; UTF-16 context matcher and bracket fallback | Core and basic comments/reply/resolve UI built; local tests; legacy reply migration built; exact markdown grouping pending |
| Comment AI threads, revisions / hash-gated undo (`CommentRevision`) | Guarded literal single edits, immutable title and turns, revisions/<reply>-<file>, SHA-256 ignoring title | Core built/tested locally; AI thread UI and legacy reply migration built; CI compiled; PC required |
| Export | Markdown save picker | Built; PC required; full Mac export layout parity pending |
| Audio briefing (`Briefing`, `BriefingPlayer`) | Summary-provider script or local fallback, Windows.Media.SpeechSynthesis → AAC with sentence marks | Script generation, local fallback, saved AAC/marks and SpeechSynthesis built; CI compiled; PC required; voice settings built; complete Thai expansion/briefing wording parity pending |
| Sync Off / folder (`Sync`, `FolderSync`) | Same selected text/media/pictures; hidden partial then rename; timestamps; confidential withdrawal | Built; local tests; PC required; six-hour timer wired; in-flight confidentiality withdrawal checks built; previous-base/rename edge cases need PC validation |
| Google Drive signed-in (`DriveSync`) | User-supplied OAuth client, PKCE loopback, drive.file, resumable upload, DPAPI/Credential Locker | OAuth PKCE, DPAPI token store, resumable chunks and HTTP retries built; portable tests and CI compilation; PC required; lost-chunk status probe implemented; no bundled credentials |
| Cloud folder discovery | OneDrive environment/registry, Dropbox info.json, DriveFS mounts | Manual folder built; automatic discovery pending |
| Retention launch/every 6h, 90-day video, audio only after transcript (`Housekeeping`) | Portable retention plan and deletion | Built; retention tests local; timer wired; verified lossless compression built; synced retention deletion pending |
| Menu bar / Dock / hotkey / startup | Shell_NotifyIcon, Ctrl+Alt+R RegisterHotKey, notification menu; unpackaged startup via HKCU Run | Built; PC required; animated recording/levels/menu parity pending |
| About version, build, changelog (`AppVersion`, `Changelog`) | Independent Windows version in windows/VERSION, bundled changelog parser | Parser tested; CI build/commit/time, first-opened time, changelog and copy report built; PC required |
| UI defaults / Reduce Motion / audio exclusivity | WinUI Fluent defaults; system controls; stop playback before recording | Basic shell and mixed Me/Others voice playback cache built; PC accessibility/motion and complete playback arbitration pending |
| --transcribe / --summarize only specified folder (`main`) | CLI dispatch before window creation; operates only on the given folder | Built and compiled on CI; Windows CLI verification required |
| Recovery after crash / retry model jobs | Repair interrupted WAV headers, recover staging, preserve recorded-note identity, retry missing-model jobs | Built; normal UI is single-instance while CLI jobs remain independent; fault-injection PC verification required |

## Platform decisions

- Keep the WinUI app unpackaged and self-contained in an unsigned ZIP for CI review. This needs no signing certificate and changes no machine-wide install state. StartupTask needs package identity; the preview uses an HKCU Run entry, removed by disabling Open at login. A future MSIX should use StartupTask.
- Use H.264 on Windows as requested, versus Mac HEVC. The initial implementation selects the most recently observed eligible app HWND, using the topmost window to break a tie; a window not seen during polling cannot be ordered by actual creation time. A monitor is the fallback when no eligible window exists. MediaComposition renders the final mixed MP4, so it currently re-encodes rather than passing the video through as Mac does. H.264 output dimensions round up by at most one pixel to satisfy 4:2:0 encoding; dynamic size changes need PC validation. Smaller uses 10 fps, Balanced/Best 15 fps with separate bitrate targets; Windows uses bitrate targets rather than the Mac HEVC quality setting.
- Classic Outlook COM is the simplest calendar adapter without a hosted service or developer credentials. New Outlook does not expose classic Outlook COM; Graph support must be explicit, user-configured, and cannot silently reuse unrelated tokens.
- Windows cannot create some names accepted on APFS. Replace `< > " | ? *` in addition to Mac's forbidden delimiters, trim trailing dots. Existing Mac folders with such names cannot be represented by the Windows filesystem; do not silently rewrite a synced source.
- A folder-sync export intentionally excludes meta.json and briefing.m4a, exactly as Mac `Sync.fileNames`. To share an editable workspace, point both apps at the **workspace itself**; the Minutes folder-sync export is a document export, not a second editable workspace.

## Evidence

- Base contains no Windows project or .NET tests.
- Local SDK 8.0.428 installed into a user directory after Homebrew's cask installer failed at sudo.
- First green CI: https://github.com/chanpollo/minutes/actions/runs/43866075484 at `111cbab`, 95/95 on Windows, WinUI build/publish, bundled engines and uploaded ZIP. Draft PR: https://github.com/chanpollo/minutes/pull/4.
- Current local gate: 147/147 on macOS (includes OAuth/PKCE, retention, frame selection, Thai numbers/time and briefing cleanup). Latest Windows validation is linked from the draft PR; test counts and hardware evidence remain separate.
- All 24 summary prompt variants match output generated directly from baseline Swift. Windows checkout line endings are normalized before loading embedded prompts.

## Remaining implementation gates

Full parity is **not complete**. These are implementation gaps, not merely unrun PC tests:

- AEC fallback for devices without a hardware/driver AEC APO; process/helper ownership and some app allow-list controls. The implemented policy queries capture effects, requests Communications processing only for speaker/line-out routes advertising AEC, and requests raw processing for other routes. It needs real-device validation.
- WYSIWYG notes and exact rich-text Markdown parser/serializer, clipboard/drop pictures, inline picture display, resizable/hide notes column, sidebar drag/reorder/swipe, full comment editing and rendered-document anchoring.
- Recording and serialized processing now use separate gates, with Recording/Queued/Transcribing rows. Real-device overlapping-call validation, dedicated page polish, full Same/New Meeting handoff, discard flow and the complete tray menu/meter animation are still missing.
- Synced retention/deletion, cloud-folder autodetection and agy account model refresh. Lost-chunk upload status probing, same-group rename safety and model-download resume are implemented and covered by synthetic HTTP contract tests.
- Complete Thai/English local briefing expansion and speaking-rate/playback/preview controls. Speech synthesis currently renders sentences separately for reliable saved marks; voice prosody differs from one Mac utterance.
- Screen re-encoding at final mux, odd-dimension scaling and dynamic resizing need finishing/validation. x64 is the only bundled architecture; ARM64 packaging is not implemented.

The first editable preview is reviewable in the draft PR. Do not promote this to a full-parity Windows release until these gates and TESTING.md are closed.

## Reproducing the cross-platform boundary check

Run `dotnet test windows/Minutes.Core.Tests/Minutes.Core.Tests.csproj`, then on macOS `python3 windows/scripts/verify-swift-interop.py`. The script imports the actual Swift MeetingMeta and BriefingInfo declarations and decodes the synthetic metadata emitted by .NET, checking the UTC date and UUID. It writes no Mac app files. This gate passed locally.

Process-loopback minimum version: [Microsoft application loopback sample](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/). Capture interop: [Microsoft CreateForWindow contract](https://learn.microsoft.com/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow).

The portable suite additionally covers cross-volume staging publication, corrupt optional JSON, legacy comment reply migration, server range mismatch/restart, failed second-pass repair, upload status probing and same-group Drive rename, legacy-note classification and per-file retention failures. The suite was last run with `dotnet test windows/Minutes.Core.Tests/Minutes.Core.Tests.csproj --nologo` (147/147). Mac app tests were not run: protected Mac files are unchanged.
