# Changelog

Newest first. One heading per build: `## <version> (<build>) — <date>`. build.sh copies this file into the app; About Minutes reads it.

## 1.0.0 (20) — 2026-11-16
- Align the macOS version with Windows 1.0.0. This version change does not add iOS support or imply Windows feature parity.
- Add a platform overview, download links and step-by-step installation instructions for Windows and macOS to the README.

## 0.7.0 (19) — 2026-11-16
- Sign In… on a summary provider in Settings that is installed but not signed in: it opens Terminal on that tool's own sign-in (claude auth login, codex login, or agy's Google sign-in), and the card shows Signed in when you come back.

## 0.6.9 (18) — 2026-11-14
- Gemini through Antigravity (agy, on your Google sign-in) is a fourth summary provider, with one model per Gemini family.

## 0.6.8 (17) — 2026-11-14
- Summaries can come from Codex (your ChatGPT sign-in, through codex exec) or from a model you pulled into Ollama, which runs on this Mac and sends nothing, as well as Claude Code. Pick one under Summary in Settings, with its model.
- Re-run with… lists the models of every provider found on this Mac, so one meeting can be summarised by each in turn. The stamp under the title says which model wrote it.
- When the Ollama app is not running, Minutes starts Ollama on port 21434 for the summary and stops it when Minutes quits.

## 0.6.7 (16) — 2026-11-13
- Recording no longer changes the call's sound on headphones: Apple's voice processing (which ducks other apps) is on only while sound comes out of loudspeakers, and switches when headphones go in or out.
- Record Now starts as "Meeting" and shows a card to name it or pick the calendar event that is on now, or "Not a calendar meeting". A title typed over the event on the Record? card drops that event's invitees.
- Your own lines are kept in lively calls: lines on your mic are dropped only when they repeat what the call said, or when the mic measurably picks up the call.
- Room meetings (Voice) list fewer phantom speakers; Thai words are no longer split between lines; a word repeated six or more times is cut to one.

## 0.6.6 (15) — 2026-11-03
- Comments are threads, as on a shared artifact: Reply under any comment; Send to Claude (⌘↩), or @claude in the text, has Claude read the whole thread, change the record where asked and answer in the thread. Claude resolves the thread itself when it made the change, and leaves it open after answering a question or asking one back.
- Each of Claude's changes has its own Undo, newest first. Your own replies can be edited and deleted. A resolved thread says who resolved it; Reopen brings it back.
- Claude's answers from 0.6.4 and 0.6.5 become the first reply of their thread.

## 0.6.5 (14) — 2026-11-03
- Notes while recording: the Notes column sits beside the recording and transcribing page. Notes are saved with the recording and are there, with the transcript, when it is done.
- Ask Claude fixes the whole record: a misheard word or name noted on the transcript is corrected in the summary too, in one go; Undo puts both back.
- ✓ on a comment resolves it: its highlight goes and it moves under Resolved at the foot of the column, where Reopen brings it back. The comment count shows open comments only.

## 0.6.4 (13) — 2026-11-03
- Ask Claude on a comment: Claude reads the comment and the text it is on, changes the summary or transcript where the comment asks for it, and replies under the comment. A question gets an answer and no change. Undo puts the text back while nothing else has changed it.
- ⌘↩ in a new comment posts it and asks Claude; ⇧⌘↩, or Comment, only posts it. Not offered when summaries are off or the meeting is confidential.

## 0.6.3 (12) — 2026-10-30
- Two meetings booked at the same time: the summary now reads which one was actually held and names the meeting after it, with its invitees. A title you typed, or an event you picked, is never changed.
- "Other meetings at this time" beside the invitees: name a meeting after another event that was on when it began.

## 0.6.2 (11) — 2026-10-30
- Spoken language in Settings › Recording: Thai, English or Detect automatically; whisper is told the language instead of guessing it, which on quiet Thai audio picked English and looped.
- In a call the microphone stays Me: its voices are told apart only in a Voice recording started by hand. A Me line that copies an Others line heard within three seconds is dropped.
- Looping lines repaired: a phrase repeated three times or more, inside a line or again and again across nearby lines, is cut to one, a stretch of them is decoded again (on the microphone in a call, only what it hears while the call side is quiet is kept), stock phrases over silence are dropped.
- Speakers: voices with under 20 seconds of speech (or under 5 % of the track's, whichever is less) are folded into the nearest voice, so a call no longer reads as dozens of Speakers.
- Renaming a meeting also renames the title line of transcript.md and summary.md.

## 0.6.1 (10) — 2026-10-30
- New Note at the foot of the sidebar (⌘N): a note of its own, no recording; Record while it is open records into it.
- About Minutes shows the version, build number and this list; the same line at the foot of Settings.

## 0.6.0 (9) — 2026-10-30
- Modes renamed Screen and Voice; the switch sits on top of the Record? card, larger.

## 0.6.0 (8) — 2026-10-29
- Screen or Voice chosen before recording: on the Record? card, in the menu bar, Dock and window menus, a default in Settings › Recording.
- New Meeting / Same Meeting for back-to-back calls; Mute Microphone; Keep Recording ends once the call's sound stops.
- Audio briefing: Listen on the summary, Play Last Briefing in the menu, voice and Preview in Settings › Summary.
- The menu bar glyph moves while recording; every live meeting listed at once; the video page opens on the first frame.

## 0.5.0 (7) — 2026-10-29
- Wider window (1440 × 860), resizable Notes column, Hide Notes (⌥⌘0).
- Notes formatted like Apple Notes; pictures of your own in attachments/.
- Swipe a meeting to pin, archive or delete; Pinned and Archived; Undo.
- Smoother switching between meetings.

## 0.4.0 (6) — 2026-10-29
- Drag meetings onto groups, reorder groups, a new group named inline; motion that follows Reduce Motion.
- Comments on the summary and transcript.
- Pictures from the video in summaries; Capture on the player.
- The Google Drive pane becomes Sync: Off, a folder another app syncs, or Google Drive signed in.
- --transcribe and --summarize work only on the folder given.

## 0.3.0 (5) — 2026-10-29
- Notes window to match the board: Record button, live Recording and Transcribing pages, confidential switch, transcript in columns, player bar with speed, groups.
- Settings window with four panes; slimmer menu bar menu; cards as on the Floating panels board; ⌃⌥R; Always record an app.
- Smaller video files at the same resolution; audio to FLAC after transcribing.
- Clean-up: meeting.mp4 deleted after 90 days by default, at launch and every 6 h.
- Confidential meetings no longer go to Drive.

## 0.2.1 (4) — 2026-10-29
- Minutes stays in the Dock: click opens the window, right-click records or summarises.
- Minute-dial app icon and menu bar glyph, red while recording.

## 0.2.0 (3) — 2026-10-29
- Meeting title and invitees from the calendar.
- Ask to record only for meeting apps; Any App switch.
- Speakers within Others (Speaker 1, 2…), renamed in the window.
- Team build: a universal .dmg, models downloaded on first launch.

## 0.1.1 (2) — 2026-10-28
- Stop recording? card about 3 s after the call releases the mic; stops itself at 30 s.
- Both tracks on one clock; echo cancellation on the mic.
- The bare binary refuses to run as an app outside Minutes.app.

## 0.1.0 (1) — 2026-10-28
- First build: recording, transcript, summary on request, workspace folder, Google Drive upload, notes window.
