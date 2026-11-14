# Minutes — plan

Records meetings on the Mac (audio and the meeting window), transcribes them locally, summarises them with the AI subscription you already pay for, keeps them in a workspace folder that can be synced (through a sync app's folder or to Google Drive), and shows them in a notes window with groups, comments and pictures from the video. A Settings window holds every option.

## Scope

- Mac first (macOS 14.2+). The team gets it later, so the meeting folder format and the summary step must not depend on Swift.
- Notes are files on disk; the app window reads and edits the same files.
- Flow: a call takes the mic → "Record this meeting?" with a default title → record → the folder lands in the workspace named `date time title` → transcript is made locally → the user presses Summarise when wanted.

## Stack

| Part | Choice | Why |
|---|---|---|
| App shell | Swift, AppKit app in the Dock with a menu bar item, floating cards, Carbon hot key (⌃⌥R) | Needs Core Audio process taps and non-activating panels; a Carbon hot key needs no Accessibility permission |
| Menu bar glyph | The dial as a template; while recording, red (`recordDot`: #d70015 light, system red dark) shape layers moved at 10 fps only while the status item is visible, still under Reduce Motion | Shows the recording is live and hearing sound, without a timer running behind the notch |
| Notes window | SwiftUI in an AppKit window, laid out after the design canvas; summary and transcript bodies are NSTextViews so a selection has a range | Groups, meetings by day, live recording and transcribing pages, video, transcript, comments, notes without a web runtime |
| Motion | `Motion.swift`: 0.15–0.25 s ease-out for appear and state changes, spring (0.3, 0.85) for drags, reorder and the selection; Reduce Motion turns moves into fades or nothing | Changes read as moves; nothing animates on first show |
| Drag | SwiftUI `onDrag` / `onDrop` with a private type (`com.enta1234.minutes.sidebar-item`) visible to this process only | Meetings onto groups and group reorder, never a file drag out of the workspace |
| Settings | SwiftUI panes (Recording, Summary, Storage, Sync) under an AppKit toolbar; `Settings.swift` holds every key and default | Every control applies at once |
| Audio | Core Audio process tap (others) + AVAudioEngine (me), 16 kHz mono WAV while recording, FLAC after the transcript (sample-exact check before the WAV goes); Mute Microphone drops mic buffers and the writer pads the gap with silence by host time | Two tracks give "Me / Others" without diarization; FLAC halves them without loss |
| Video | ScreenCaptureKit, the meeting app's newest window of at least 320 × 200 (Teams opens each meeting in its own window; whole display if none) at its own pixel size, HEVC with a constant-quality target per preset (Smaller 10 fps, Balanced and Best 15 fps), key frame every 30 s; Intel gets an average bit rate | Only the call; full resolution, and size follows motion rather than time (20 MB per hour for a Balanced call window) |
| Final media | `meeting.mp4`: the video passed through plus both WAVs mixed to AAC | One file to watch; no video re-encode |
| Transcription | whisper.cpp `whisper-cli`, large-v3-turbo q5_0, Silero VAD, language auto per track | Offline; Thai and English both verified |
| Speakers | sherpa-onnx offline diarization on `others.wav`: pyannote segmentation 3.0, 3D-Speaker CAM++ embeddings, cluster threshold 0.65 | Offline; "Speaker 1, 2…" by first appearance, renamed by hand in the notes window |
| Summary | On request, or automatically when set. `claude -p` with no tools, MCP or settings; model Sonnet by default, Opus or Haiku selectable; Thai, English or the meeting's language; Off refuses; confidential meetings only with an explicit request | Runs on the Claude subscription login; nothing else in the session can act |
| Audio briefing | `claude -p` (the summary model, no tools) turns `summary.md` into a spoken script (`briefing.md`), or a local script without Claude for confidential meetings and summaries Off; AVSpeechSynthesizer with the voice picked in Settings writes `briefing.m4a` (AAC) with each sentence's start time in `meta.briefing`; one sound at a time across the briefing, the meeting player and the voice preview, and none while recording | The audio is made and kept on the Mac; only the script is synced |
| Pictures | After the transcript: the video sampled once a second on a 64×36 brightness grid; moments where it changed and then stayed still ≥ 3 s (at most 40) saved as `frames/hh-mm-ss.jpg`, read with Vision (th + en) into `frames/frames.json`; the list goes into the summary input and Claude places up to six; unknown links are dropped | Slides and shared documents illustrate the points without giving Claude any tools |
| Comments | `comments.json` (quote, ≈32 characters each side, transcript time, author, dates), re-anchored by quote and context after a re-run or speaker rename; `comments.md` made from it for the synced copy | Medium-style margin comments that survive a re-summarise |
| Comment threads (artifact-style) | `claude -p` gets the comment, the text it is on (and the transcript for a summary comment) and and the whole thread returns `{reply, edits[{file, find, replace}], resolve}`; the reply joins the thread and `resolve` closes it (`resolvedBy` Claude) over summary.md and transcript.md both; each find must match once, the title line and a transcript's turns must stay; the text before is kept in `revisions/<reply id>-<file>` for that reply's Undo, allowed while every changed file's hash still matches; ✓ sets `resolvedAt` | Fix one point now, the way a comment on a shared doc gets an edit and a reply, without re-running the whole summary |
| Workspace | A folder the user picks (default `~/Documents/Meetings`); recordings are staged in Application Support and moved in when finished | Plain files; a synced folder never sees half-written audio |
| Sync | One mode at a time behind `Sync`: Off, `FolderSync` (copy into `<sync app folder>/Minutes/<group>/<meeting>`, hidden temp name then rename, unchanged files skipped by size and date in `meta.sync`, retried every 6 h when the folder is away), or `DriveSync` (OAuth desktop client, PKCE, loopback on 127.0.0.1, scope `drive.file`, resumable uploads, refresh token in the Keychain). Uploads follow the mode; a meeting marked confidential is withdrawn from both whatever the mode | The sync-app folder needs no set-up; Drive signed in needs no sync app |
| Clean-up | `Housekeeping`: at launch, every 6 h of wall time and on request; video after Keep video (default 90 days), tracks after Keep audio (default never, and only with a transcript); optionally the synced copies | Video is most of the disk; transcripts, notes, comments and pictures are never deleted |
| Search | In-memory over titles, transcripts, notes and comments; SQLite FTS5 later | Small workspaces first |
| Calendar | EventKit: the event on now prefills the title; its invitees go to meta.json and help the summary spell names | Works with any calendar added to macOS Calendar (Google, Exchange, iCloud) |

## Meeting folder

```
<workspace>/groups.json   group ids and names
2026-10-27 1400 Sprint review/
  meta.json        id, title, mode (screen / voice; older files call / inPerson; missing is screen), start, end, app, invitees, group,
                   confidential, summary model, briefing (voice, length, sentence marks, source summary),
                   videoDeletedAt / audioDeletedAt, pinnedAt / archivedAt, Drive ids
  me.flac          me.wav until the transcript is made
  others.flac
  meeting.mp4      meeting window + mixed audio; deleted after Keep video
  transcript.md    timestamped, Me / Others or Speaker 1, 2…
  summary.md       summary, decisions, action items (owner, due), pictures — only after a summary
  briefing.md      the spoken briefing's script — only after Listen or After every summary
  briefing.m4a     the briefing spoken on this Mac; never synced
  notes.md         Markdown from the formatted notes editor; Capture adds ![hh:mm:ss](frames/…)
  attachments/     pictures pasted, dropped or inserted into the notes, as ![](attachments/<name>)
  comments.json    comments and their anchors
  comments.md      made from comments.json after every change to the comments, summary, transcript or title
  frames/          hh-mm-ss.jpg and frames.json (time, file, text read from it)
```

The synced copy gets `meeting.mp4` (or the two tracks when there never was a video), `transcript.md`, `summary.md`, `notes.md`, `comments.md`, `briefing.md` and the pictures the summary or notes show (`frames/` and `attachments/`), as Settings allow, under `Minutes/<group>/<folder name>` (`Minutes/<folder name>` without a group). `meta.json` and `briefing.m4a` stay local: `meta.json` records the sync state, so copying it would change it on every pass. A confidential meeting is not synced; marking one after it was synced removes the copy (to the Drive trash with Google Drive).

## Build order

1. **Title and workspace** — default title in the record prompt, editable; Choose Workspace…; staging then move; `meta.json`.
2. **Summary on request** — Summarise button on "Transcript ready" and in the notes window; model menu (Sonnet default); `Minutes --summarize <folder> [--model opus]`.
3. **Screen video** — meeting window capture, `meeting.mp4` after stop; Record Screen switch; Screen Recording permission.
4. **Notes window** — meetings by day with search; page with an editable title (renames the folder), video player, Summary / Transcript tabs (click a line to seek), `notes.md` editor, Summarise with model choice.
5. **Google Drive** — Connect / Disconnect; upload after transcription and after each summary or rename; retry on the next launch.
6. **Round 3, to the design canvas** — notes window with groups, live recording and transcribing pages, confidential switch, export, video above the tabs; Settings window; menu bar menu with levels and progress; cards; ⌃⌥R; video presets at full resolution; FLAC tracks; clean-up cycle; Drive folders per group.
7. **Round 4** — drag meetings onto groups and reorder groups; inline group naming; motion for windows, cards, list changes, selection and pages, with Reduce Motion; comments on the summary and transcript; pictures from the video in summaries and Capture; Sync pane with a sync-app folder or Google Drive signed in. The command line works only on the folder it is given.
8. **Round 5** — wider window (1440 × 860, resizable right column, Hide Notes ⌥⌘0); Notes formatted like Apple Notes over plain Markdown, with pictures of your own in `attachments/`; swipe a meeting to pin, archive or delete, Pinned and Archived in the sidebar, Undo toast and ⌘Z; summary and transcript laid out off the main thread and the player made after the page shows.

9. **Round 6, recording modes** — Screen (mic, Mac audio, meeting window) or Voice (mic and Mac audio, no screen), chosen on the Record? card (kept per app), by Record Screen / Record Voice in the menu bar, Dock and window menus (which set the default), and by ⌃⌥R and the window's Record button (the default). Settings' Screen video switch is migrated into the default and app modes; the first names, call and inPerson, are still read and rewritten at the next launch. Voice also separates the voices on the mic, and its summary prompt says the Speaker labels include the recorder. The menu bar glyph moves while recording; the notes window lists the recording, the transcription and every meeting waiting for it at once; the audio briefing is merged (Listen, player, Play Last Briefing, Settings › Summary). Last pass: one red for every record dot and the glyph; New Meeting / Same Meeting when the call app takes the mic back while the stop card is up; a start by hand while the Record card is up records that card's call; Mute Microphone; Keep Recording ends once the call's sound has stopped too; room events first for a Voice title; the newest call window is captured; nothing plays while recording.

10. **New Note** — a note made by hand from the foot of the sidebar, ⌘N, the menu bar or the Dock: a meeting folder with `meta.json` (`note: true`) and an empty `notes.md`, dated now, in the chosen group, titled as typed. Its page is the notes editor itself, so the Notes column and ⌥⌘0 are off; the row reads "Note". A recording started by hand while the note is open on screen (window button, menus, ⌃⌥R, Dock; not when the window is on another Space or covered) goes into it: the files join the note's folder, which keeps its id, title and folder name, while `startedAt` becomes the recording's start so the duration, the transcript header and the summary date are the call's; the calendar event is ignored for a note, and the Record? card never records into one. Housekeeping, transcription, summaries and the command line skip notes; export writes the title and notes.
11. **Version and build number** — `VERSION` (0.6.1; round 7 becomes 0.7.0) and `BUILD_NUMBER` (a counter build.sh raises by one per app build, this install being 10; not `BUILD`, which is `build/` on a case-insensitive disk) at the repo root, stamped into the app's Info.plist with the build time and commit; `docs/CHANGELOG.md` (one heading per build, newest first) copied into the app. About Minutes replaces the standard About panel: version, build, built and installed times, Copy for a bug report, and the changelog with the running build marked; the same line at the foot of every Settings pane. Builds 1–9 are numbered after the fact (6–9 from the install times on the Progress board, 1–5 from memory).
12. **Transcript quality** — the owner's own LINE and Teams recordings of 30 Oct showed 57 Speakers and no Me, English loops on Thai audio and stale `# LINE meeting` headers. Spoken language setting (Thai by default on a Thai Mac) passed to whisper with `--suppress-nst`; the microphone told apart only in a Voice recording with no call app; a leak suppressor for the speaker heard by the mic (built as an STFT gain against the aligned Others track, measured and left out of the patch: it lost 14–19 % of the owner's lines and removed no copies; the port is kept in the scratchpad) and a dedupe of Me lines copying Others; `TranscriptCleaner` collapsing looped phrases (a loop that says nothing else is dropped only under p 0.5), runs of identical lines, the same line said again within two minutes or a long one said three times anywhere in the track, and the pieces of such a sentence around its loops (teams1432: one invented sentence 49 times over 75 minutes of the owner listening), dropping stock fillers under p 0.5 and decoding looping stretches (repaired lines within 10 s of each other) again with `-mc 0`, where on the mic in a call the second pass's lines under far-end speech are dropped as leak (teams1432: 210 of 225); diarizer voices under min(20 s, 5 %) folded into the nearest voice at threshold 0.65 (0.80 merged real people on two of the four recordings); rename rewriting the title line of transcript.md and summary.md.

13. **Meetings booked over each other** — when two or more calendar events were on as the recording began and the title is still one of them, the summary gets them all, numbered, with their invitees instead of the guessed event's, and answers with an `Event: <n>` first line that Minutes strips; another event than the guess renames the meeting, takes its invitees and marks it confidential when Settings say so for external guests. A title typed by hand, an event picked by hand (`eventPicked` in meta.json), a note and the command line are never renamed. The page's invitee row has "Other meetings at this time" to pick one by hand.

## Later

- Codex CLI and API key as summary providers.
- Signed and notarised build for the team; Windows client on the same folder format.

## Open points

- Recording consent: other participants are not told the call is recorded.
- Google Drive signed in from Minutes needs an OAuth client ID (Google Cloud, type Desktop app) before Connect works; the sync-app folder does not.
- Switching meetings still holds the main thread for 30–80 ms on the sample workspace. Very long notes are parsed and styled on the main thread when a meeting opens (about 50 ms for 3,000 lines); building them on the page queue would remove that.
- A call app's own mute is not read; Mute Microphone is by hand. Reading Teams' mute through Accessibility could come later.
- While the mic is released but the call app still plays sound, the stop countdown still runs (only Keep Recording looks at the sound), since whether Teams keeps its output open after a call has not been checked.
- A call joined already muted, in an app that releases the mic while muted, is not offered until it takes the mic.
- Comments cannot be placed on the action-items table.
- A Screen recording without Screen Recording permission records audio only; the Transcript ready card says the video was not recorded.
- The notes window does not play `screen.mov` when combining the video failed; the bar plays the audio tracks instead.
