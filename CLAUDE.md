# Paper Trail

Personal document archive for iPhone, iPad and Mac. It captures receipts, invoices and letters from any source, files them into iCloud Drive with consistent names, and tracks unpaid bills in Apple Reminders.

Full design spec: https://claude.ai/artifact/3xgTR4oqguhXEpCdpx2rCd. When this file and the spec disagree, this file wins; update the spec afterwards.

## Key decisions (settled, don't revisit without asking)

- **One SwiftUI multiplatform app** (iOS, iPadOS, macOS) from one codebase.
- **Files in iCloud Drive are the source of truth.** The SwiftData index (synced with CloudKit) holds extra metadata and must be rebuildable by re-scanning the folders.
- **Folder structure:** `Paper Trail/<Owner>/<Year>/<Category>/`. Owners (Company1, Company2, Private) and categories are user settings. Year = year the document was received.
- **File name:** `YYYY-MM-DD Sender - Description.pdf`
  - Date = date received (not the date printed on the document; store that one separately).
  - Sender = short normalised name ("KPN", not "KPN B.V. Klantenservice").
  - Description = at most ~6 words.
  - Strip `/ : \ ? * " < > |`. On a name collision append ` (2)`, ` (3)` and so on.
  - Everything is stored as PDF.
- **Special folders:** `Paper Trail/Inbox/` (watched drop zone) and `Paper Trail/Needs Review/`.
- **Bills go to Apple Reminders** via EventKit, in a list called "To pay" by default (one list per owner is a setting). Completing the reminder marks the bill paid in the app. Never build a separate in-app to-do list.
- **All OCR and classification run on the device** (Vision + Foundation Models). Never send document content to an external AI or cloud service.
- **Email intake = a dedicated IMAP mailbox** checked by the Mac app (menu-bar helper), with opportunistic checks on iOS. There is no inbound-mail server.
- The app proposes, the user confirms (review queue). Rules learned from corrections run before the model.

## Tech stack

| Concern | Choice |
|---|---|
| UI | SwiftUI |
| Scanning | VisionKit `VNDocumentCameraViewController` (iOS/iPadOS only) |
| OCR | Vision text recognition; PDFKit for PDFs that already contain text |
| Classification | Foundation Models framework, guided generation into a `@Generable` struct |
| Index | SwiftData + CloudKit |
| Search | Core Spotlight |
| Bills | EventKit (Reminders) |
| Email | IMAP: evaluate `apple/swift-nio-imap` first (phase 5) |
| Project file | XcodeGen (`project.yml`). Don't hand-edit `.xcodeproj` |

**Deployment targets:** iOS 26 / iPadOS 26 / macOS 26 (needed for Foundation Models). Confirm with the user before lowering.

Check API details against the current Apple documentation. Don't guess API names, entitlements or Info.plist keys; verify them.

## Project layout

```
project.yml                 XcodeGen spec (source of truth for targets and settings)
PaperTrailKit/              Local Swift package: platform-independent logic, fast to test
  Sources/PaperTrailKit/
    Models/                 Document, Bill, Owner, Category, Rule, MailAccount
    Filing/                 FileNamer, ArchivePaths, collision handling
    Classification/         ClassificationResult, rule engine, model prompt
    Bills/                  Bill state machine, reminder text formatting
  Tests/PaperTrailKitTests/
    Fixtures/               Synthetic sample documents ONLY
PaperTrail/                 App target (shared SwiftUI)
  App/  Views/  Services/   Services = iCloud, Scanner, OCR, Reminders, Spotlight
PaperTrailShare/            Share Extension (phase 3)
PaperTrailMailHelper/       macOS menu-bar helper (phase 5)
```

Keep logic in `PaperTrailKit` wherever possible, so it can be tested with `swift test` without a simulator. Put framework-specific code (VisionKit, EventKit, iCloud) behind small protocols in the app target so it can be faked in tests.

## Commands

```bash
xcodegen generate                       # after any change to project.yml
cd PaperTrailKit && swift test          # fast logic tests
xcrun simctl list devices available     # find a simulator name
xcodebuild -scheme PaperTrail -destination 'platform=iOS Simulator,name=<device>' build test
xcodebuild -scheme PaperTrail -destination 'platform=macOS' build test
```

Before saying a change is done, run `swift test` and build the app for both iOS Simulator and macOS. Report failures honestly, with the output.

## Things the user does by hand

Claude Code can't do these. Ask the user when one is needed:
- Signing in with the Apple Developer account, picking the team, and setting the bundle identifier (placeholder: `com.example.papertrail`; iCloud container `iCloud.com.example.papertrail`). Set `DEVELOPMENT_TEAM` and `PAPERTRAIL_BUNDLE_ID` in `project.yml`, plus the literal `NSUbiquitousContainers` key there; everything else derives the container ID from the bundle ID.
- Enabling capabilities in Xcode if XcodeGen can't (iCloud Documents, CloudKit, App Groups for the Share Extension).
- Running on real iPhone and iPad devices. Camera scanning and Reminders/iCloud sync must be tested there.

## Conventions

- Swift 6, strict concurrency. Use async/await, no completion handlers in new code.
- Code, comments, commit messages and docs in English. UI text in English with localisation strings from the start (Dutch to follow).
- Errors shown to the user say what went wrong and what to do; never fail silently when filing a document. Never lose a file: write to the destination first, verify, then remove from Inbox.
- File operations on iCloud Drive go through `NSFileCoordinator`.
- Only one device processes an intake item: claim it in the index before processing.

## Privacy and secrets

- **Test fixtures must be synthetic.** Never commit or paste real receipts, invoices, bank details or letters into the repo or into prompts. Use invented companies, amounts and IBANs (for example the test IBAN format `NL00TEST0123456789`).
- Mailbox passwords live in the Keychain only. No secrets in code, `project.yml`, Info.plist, logs or git.
- Never log extracted document text outside debug builds.

## Build phases

1. **Capture and file:** project setup, iCloud container, settings for owners and categories, camera scan, OCR, manual filing with the naming rules. ← start here
2. **Smart proposals:** on-device classification, review screen, learned rules, duplicate check (content hash + sender/amount/invoice number).
3. **More ways in:** Share Extension, watched Inbox folder, Mac drag and drop.
4. **Bills in Reminders:** create reminder (title `Pay <Sender> · € <amount>`, due date, notes with IBAN/reference/file path, URL back into the app), listen for completion, open-bills overview, copy buttons.
5. **Email:** Mac menu-bar helper, IMAP fetching, HTML email to PDF.
6. **Polish:** Spotlight, searchable PDFs (invisible OCR text layer), widgets, Shortcuts actions, Face ID lock.

Finish and test one phase before starting the next. Commit in small, working steps.

## Open questions (ask the user, don't assume)

- How well does the on-device model handle Dutch? Test early; sender rules are the fallback.
- ~~Which devices does the user have?~~ Answered 2026-11-22: MacBook Pro M4 Max and iPhone 17 Pro Max, both with Apple Intelligence support. No iPad mentioned yet; keep the iPad layout working, but it is untested on hardware.
- One "To pay" list or one per owner? (Default: one list.)
- Direct-debit bills: a "check the debit" reminder, or none?
- Keep the original email next to the PDF?
- Dedicated mailbox: iCloud+ address or own domain?
