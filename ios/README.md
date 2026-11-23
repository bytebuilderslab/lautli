# lautli for iPhone (prototype)

Phase 1 of epic #33: a companion app and a dictation keyboard. The keyboard can't record audio, so the app records, uploads each clip to a lautli transcription server, and gives the text back to the keyboard.

## How a dictation works

1. In Notes (or any app) the user switches to the lautli keyboard and taps the microphone.
2. If no session is running, the keyboard writes a `start` command to the shared App Group and opens `lautli://dictate`. The app starts its audio session, begins recording at once, and asks the user to swipe back (◀ in the status bar). Since iOS 26.4 a keyboard can't return the user to the host app automatically.
3. Back in Notes, the keyboard shows the recording time. Stop sends a `stop` command over a Darwin notification. The app, still running in the background on the `audio` background mode, finishes the AAC clip and sends `POST /api/v1/transcriptions`.
4. The keyboard shows the text with **Insert text** and **Discard**. Insert puts it at the cursor and acknowledges the result.
5. The session stays warm for 5 minutes after the last dictation (orange microphone indicator on), so later dictations start straight from the keyboard. Then it releases the microphone and the next tap opens the app again.

`LautliKit` holds the contract (`DictationContract.swift`), the session state machine (`DictationSession.swift`) and the keyboard's button logic, all covered by `swift test --package-path ios/LautliKit`. Each shared file has one writer (app: snapshot, keyboard: command). A heartbeat in the snapshot tells the keyboard whether the app is still alive.

## Run on an iPhone

1. `echo 'DEVELOPMENT_TEAM = <your team ID>' > ios/Config/Local.xcconfig` (gitignored).
2. Open `ios/Lautli.xcodeproj`, choose the `Lautli` scheme and your iPhone, and run. Xcode registers the App Group `group.io.github.ameetmadan.lautli` for both targets.
3. Start the Mac dev server (below) and enter the address it prints in the app (plain HTTP to local addresses is allowed).
4. Settings → General → Keyboard → Keyboards → Add New Keyboard → lautli, then turn on Allow Full Access.

## TestFlight

1. In [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** → New App: platform iOS, bundle ID `io.github.ameetmadan.lautli` (after step 2, Xcode has registered it).
2. Set your team in `ios/Config/Local.xcconfig`, open the project, choose **Any iOS Device**, then Product → Archive. Automatic signing registers both bundle IDs and the App Group.
3. In the Organizer: Distribute App → TestFlight & App Store → Upload.
4. Once processing finishes (usually 10–30 minutes), add yourself under TestFlight → Internal Testing. Internal testers (up to 100 App Store Connect users) need no Beta App Review. External testers do, and the reviewer will need a working server URL.

Bump `CURRENT_PROJECT_VERSION` in the project before every upload, since App Store Connect rejects a reused build number. The app icon is the Mac icon cropped to full bleed; it needs a proper iOS version before release.

## Mac dev server

Until the hosted server exists (#33 Phase 3), the Mac serves the same API with the desktop worker's model and cleanup:

```sh
WHISPER_MODEL_PATH=.models/flix-swissgerman-full .venv/bin/python -m worker.lautli_worker.dev_server
```

It loads the model in the background (`/ready` returns 503 until it has loaded), then logs `{"event": "listening", "url": "http://<lan-ip>:8765"}`. Enter that URL in the app. Logs hold request IDs, sizes, status codes and durations, never audio or text. It decodes clips with macOS `afconvert` into a temporary directory that is deleted after each request. It has no authentication, so run it only on a network you trust. On an M1 Pro a warm 6-second clip takes about 8 seconds.

Server contract: the request body is the AAC clip (`Content-Type: audio/mp4`) with an `X-Request-ID` header. The response is `{"data": {"text": "..."}, "error": null, "meta": {...}}`, and anything else counts as a failure.

## Known gaps

- Verified only in the iOS simulator (app side, driven through the shared container) against a stub server. Device behavior, App Review guideline 4.4.1 (the keyboard opens its app through the responder chain) and the "instant dictation" approach without an app switch are still unverified.
- Phase 1 keyboard only: microphone, space, delete, return and the globe key. No letter keys yet, no app icon, English UI only.
