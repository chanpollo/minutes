Windows 1.0.0 is the first numbered Windows release of Minutes, built with .NET 8 and WinUI 3. The macOS app remains at 0.7.0.

Download Minutes-1.0.0-win-x64.zip, extract the entire folder, and run Minutes.App.exe. The ZIP is unsigned. Windows 10/11 x64 is required; app-specific audio capture requires build 20348 or later, with whole-system capture as fallback. Speech models download on first run. Summary-provider CLIs and Google OAuth credentials are user-supplied.

Includes recording, local transcription, summaries, classic Outlook calendar integration, notes/comments, sync, OCR and audio briefing implementations. Ships pinned whisper.cpp, sherpa-onnx and FLAC tools.

Known limitations: full macOS feature parity is not complete. Rich notes, parts of recording handoff/tray behavior, cloud-folder discovery, synced retention and full briefing controls remain unfinished. Recording, echo cancellation, calendar, provider sign-in, sync and UI behavior have not been validated on a real Windows PC. Version 1.0.0 does not imply these acceptance checks have passed.

Validation: 147 portable tests pass on macOS and Windows. The Windows workflow builds and publishes the WinUI application, bundles native tools and produces this ZIP. Original Swift metadata declarations successfully decoded synthetic .NET metadata.

- [Parity and remaining implementation](https://github.com/chanpollo/minutes/blob/main/windows/docs/PARITY.md)
- [Real-PC testing checklist](https://github.com/chanpollo/minutes/blob/main/windows/docs/TESTING.md)
- [Windows build runs](https://github.com/chanpollo/minutes/actions/workflows/windows.yml)
