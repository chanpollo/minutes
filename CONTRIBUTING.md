# Contributing to Minutes

Help make meeting records more useful. Bug reports, documentation fixes, accessibility improvements and real-device testing are welcome, as well as code.

## Start with an issue

Search [existing issues](https://github.com/chanpollo/minutes/issues) before opening a new one. For a feature, a large refactor, a new dependency or a new platform, describe your proposal in an issue and agree on scope with a maintainer before building it. Small documentation and typo fixes can go straight to a pull request.

For a bug, include:

- Minutes version and build, operating system version and CPU architecture.
- Steps to reproduce, expected behavior and actual behavior.
- Relevant logs or screenshots with personal information removed.
- Whether you reproduced it in the published app or a source build, and the commit if known.

Use synthetic meetings and sample transcripts. Do not attach real meeting recordings, attendee details, credentials or private workspace files to an issue or PR.

## Set up a development checkout

Fork the repository on GitHub, then clone your fork:

```sh
git clone https://github.com/YOUR-USERNAME/minutes.git
cd minutes
git remote add upstream https://github.com/chanpollo/minutes.git
git fetch upstream
git switch -c fix/meeting-title upstream/main
```

Use a short descriptive branch such as `fix/meeting-title`, `feature/transcript-search` or `docs/windows-install`. Keep each PR focused on one change.

### macOS

You need macOS 14.2 or later and the Swift toolchain (Xcode or Command Line Tools).

```sh
swift test
./build.sh
open build/Minutes.app
```

For recording and transcription setup, follow [Build from source](README.md#build-from-source). `setup.sh` downloads speech tools and models; it is not needed for the changelog unit tests. Use a temporary workspace and a short synthetic recording for manual checks.

`build.sh` increments `BUILD_NUMBER`. Leave release versions, build counters and release changelog entries out of a normal contribution unless the maintainer asks for them.

### Windows

Install the .NET 8 SDK. The portable core tests can run on Windows, macOS or Linux:

```sh
cd windows
dotnet test Minutes.Core.Tests/Minutes.Core.Tests.csproj
```

Building and running the WinUI application requires Windows x64, Visual Studio 2022's Windows application development workload and a Windows SDK. Follow the [Windows build instructions](windows/README.md#build-on-windows-x64). Do not try to build WinUI on macOS or Linux.

For recording, playback, calendar, sign-in or sync changes, use the [real-PC checklist](windows/docs/TESTING.md). A successful compile or portable test run does not verify device behavior. Record what you tested and what remains untested.

## Make and verify your change

- Follow the surrounding code and keep comments for non-obvious intent.
- Keep code, documentation and commit messages in English.
- Add a regression test when it meaningfully demonstrates a bug or changed behavior. Documentation-only changes need link and content checks rather than new unit tests.
- Run the relevant checks before and after the change. Include the command, outcome and test counts in your PR; identify existing failures separately.
- For UI changes, include screenshots and manual steps. State which platform, OS and device you used.
- For shared workspace files, verify that the other platform can still read them. Discuss format or migration changes before implementation.
- Update the relevant docs and [Windows feature coverage](windows/docs/PARITY.md) when behavior changes.
- Do not include generated apps, speech models, build artifacts, credentials or unrelated formatting changes.

## Open a pull request

1. Commit your change with a short message such as `fix: preserve the edited meeting title` or `docs: clarify Windows installation`. Do not add AI/tool signatures or co-author footers.
2. Push the branch to your fork:

   ```sh
   git push -u origin fix/meeting-title
   ```

3. Open a PR from your fork's branch to **chanpollo/minutes → main**. Use a draft PR if you want early feedback.
4. Fill in the PR template: problem, resulting behavior, issue link, validation and remaining limitations.
5. Respond to review comments and rerun affected checks after changes. Keep the PR focused; discuss additional work in a separate issue.

The Windows workflow runs on pushes to `main` and `feature/windows-app`, pull requests to `main`, and manual dispatch. It builds and packages artifacts without publishing a release. A maintainer arranges any additional device checks.

A maintainer reviews and merges accepted changes. If you disagree with feedback, explain the use case and tradeoff in the PR so it can be resolved there. After the PR is merged, delete your contribution branch. Maintainers handle version bumps, signing, tags and published downloads separately; a merge does not mean a release is available.

## License and third-party code

Minutes uses the [MIT License](LICENSE). By submitting a contribution, you agree to provide it under that license and confirm you have the right to contribute it. Do not introduce third-party code without identifying its source and compatible license. Bundled Windows tools have their own [third-party notices](windows/docs/THIRD-PARTY.md).

Follow the [code of conduct](CODE_OF_CONDUCT.md) in project discussions. Report suspected vulnerabilities using [SECURITY.md](SECURITY.md), rather than including exploit details in an issue or PR.
