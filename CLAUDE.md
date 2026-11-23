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
- **Bills go to Apple Reminders** via EventKit, one list per owner ("To pay – <Owner>") in the **iCloud** Reminders account, never Exchange (its reminder IDs differ per device). Completing the reminder marks the bill paid in the app. Never build a separate in-app to-do list. Direct debits get no reminder.
- **Paying is a two-step approach** (decided 2026-11-23): Reminders remember the bill; Paper Trail helps pay it. Per owner a payment method setting: **SEPA batch file** (`pain.001` XML to upload in business internet banking; for the Rabobank business account. ASN Bank business banking has no file import (checked by the user 2026-11-23), so that company uses QR codes) or **EPC QR code + copy buttons** (for Private at Rabobank; shown large on the Mac so the phone can scan the screen). Paper Trail never sends payments itself and never uses PSD2 payment initiation. An exported bill is "exported", not paid; paid stays = reminder completed. The paying account per owner (name, IBAN, optional BIC) is a setting, stored like the other settings, never in code or logs.
- **All OCR and classification run on the device** (Vision + Foundation Models). Never send document content to an external AI or cloud service.
- **Email intake = a dedicated IMAP mailbox** checked by the Mac app, with opportunistic checks on iOS. There is no inbound-mail server. Decided 2026-11-23: an **iCloud+ address** (IMAP with an app-specific password, stored in the Keychain only); the Mac app keeps running with a **menu-bar icon** (no separate helper target) and can start at login; only PDFs are filed (**no .eml kept**); processed emails are **moved to a "Processed" mailbox folder**, never deleted.
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
| Email | Own minimal IMAP client on Network.framework (TLS); own MIME parsing in PaperTrailKit. `apple/swift-nio-imap` was evaluated 2026-11-23 and not used: v0.5, README says "not yet ready for use in production", and it adds swift-nio, swift-nio-ssl, swift-nio-extras, swift-log and swift-collections. iCloud: `imap.mail.me.com:993`, TLS, app-specific password ([Apple](https://support.apple.com/en-us/102525)). |
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

1. **Capture and file:** project setup, iCloud container, settings for owners and categories, camera scan, OCR, manual filing with the naming rules. ✅ Done 2026-11-23: tested on MacBook Pro and iPhone 17 Pro Max, including two-way sync, name collisions, multi-page scans, Mac PDF import and offline filing.
2. **Smart proposals:** ✅ Done 2026-11-23: tested on MacBook Pro and iPhone 17 Pro Max. Dutch/English model evaluation (`PAPERTRAIL_MODEL_EVAL=1 swift test --filter ModelEvaluation`), on-device suggestions corrected by `ExtractionChecks`, learned sender rules (`SenderRules`, stored as `FilingRuleRecord`, synced), duplicate check (`DuplicateDetector`: same file, same sender + reference, or same sender + amount + date), Needs Review queue (the `Needs Review` folder is the queue; Review Later in the filing screen).
3. **More ways in:** ✅ Done 2026-11-23: tested on MacBook Pro and iPhone 17 Pro Max. Drag and drop on the main screen, watched `Inbox` folder (moved to Needs Review while the app is open; the move is the claim), Share Extension `PaperTrailShare` (copies into the App Group's `Incoming` folder; the app moves it to Inbox). App Group: `group.nl.rolandstilting.papertrail` on iOS (registered), `67YRLXTX42.nl.rolandstilting.papertrail` on macOS, set by `PAPERTRAIL_APP_GROUP` in `project.yml`.
4. **Bills in Reminders and paying:** ✅ Done 2026-11-23: tested on MacBook Pro and iPhone 17 Pro Max. Payment settings per owner, reminders in "To pay – <Owner>" lists (created after filing, paid state synced from completion, `papertrail://bill/<id>` link back), Open Bills with copy buttons and EPC QR code (the Rabo App scans it), SEPA export (`SEPACreditTransfer`, pain.001.001.03, betalingskenmerk as structured CUR reference). **SEPA upload is untested:** the user's Rabobank business banking version has no file import either, so all owners currently pay by QR code. Test the file at a bank that imports pain.001 before relying on it.
5. **Email:** ← next. Mac menu-bar helper, IMAP fetching, HTML email to PDF.
6. **Polish:** Spotlight, searchable PDFs (invisible OCR text layer), widgets, Shortcuts actions, Face ID lock.

Finish and test one phase before starting the next. Commit in small, working steps.

## Open questions (ask the user, don't assume)

- ~~How well does the on-device model handle Dutch?~~ First test 2026-11-23 (macOS 27.0.1, 10 synthetic docs, `PAPERTRAIL_MODEL_EVAL=1 swift test --filter ModelEvaluation`): Dutch is officially supported and reads well (amounts 10/10, sender 9/10, document date 9/10). Weak spots are judgement, not language: it invents due dates (3/10), treats direct debits as unpaid and takes the recipient's own IBAN, and files receipts as invoices. Rules in `ExtractionChecks` now validate the output against the text (2026-11-23: with checks 10/10 on every field except category 8 and reference 9). Remaining misses: a direct-debit year statement filed as Tax, a bank letter as Letters. Re-run the evaluation after each change. Real-document test on Mac and iPhone (2026-11-23) went well; two misses there led to fixes: a shop receipt saying "te betalen" (receipt check) and a "binnen 14 dagen" payment term (due date = document date + term). Apple Intelligence on iPhone needs the device and Siri languages to match.
- ~~Which devices does the user have?~~ Answered 2026-11-22: MacBook Pro M4 Max and iPhone 17 Pro Max, both with Apple Intelligence support. No iPad mentioned yet; keep the iPad layout working, but it is untested on hardware.
- ~~One "To pay" list or one per owner?~~ Answered 2026-11-23: one per owner.
- ~~Direct-debit bills: a "check the debit" reminder, or none?~~ Answered 2026-11-23: none.
- ~~Keep the original email next to the PDF?~~ Answered 2026-11-23: no, PDF only.
- ~~Dedicated mailbox: iCloud+ address or own domain?~~ Answered 2026-11-23: iCloud+ address.
