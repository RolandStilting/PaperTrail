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
- **Paying is a two-step approach** (decided 2026-11-23): Reminders remember the bill; Paper Trail helps pay it. Per owner a payment method setting: **SEPA batch file** (`pain.001` XML to upload in business internet banking; for the Rabobank business account. ASN Bank business banking has no file import (checked by the user 2026-11-23), so that company uses QR codes) or **EPC QR code + copy buttons** (shown large on the Mac so the phone can scan the screen). The Rabobank app refuses EPC QR codes (user, 2026-11-23): for Rabobank owners, show the invoice's own iDEAL/Tikkie QR code or pay link instead; Paper Trail can't make an official iDEAL code for someone else's invoice. Paper Trail never sends payments itself and never uses PSD2 payment initiation. An exported bill is "exported", not paid; paid stays = reminder completed. The paying account per owner (name, IBAN, optional BIC) is a setting, stored like the other settings, never in code or logs.
- **All OCR and classification run on the device** (Vision + Foundation Models). Never send document content to an external AI or cloud service.
- **Email intake = a dedicated IMAP mailbox** checked by the Mac app, with opportunistic checks on iOS. There is no inbound-mail server. Decided 2026-11-23: an **iCloud+ address** (IMAP with an app-specific password, stored in the Keychain only); the Mac app keeps running with a **menu-bar icon** (no separate helper target) and can start at login; only PDFs are filed (**no .eml kept**); processed emails are **moved to a processed folder**, never deleted. The mailbox is an **iCloud alias on the user's own account** (option A, 2026-11-23): an icloud.com rule moves the alias's emails to the folder "Paper Trail"; Paper Trail reads only that folder and moves filed emails to "Paper Trail Processed". It refuses the Inbox unless the whole account is marked as dedicated to Paper Trail.
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
swift Tools/make-app-icon.swift         # after changing Tools/AppIcon-source.png (writes all app icon sizes)
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
4. **Bills in Reminders and paying:** ✅ Done 2026-11-23: tested on MacBook Pro and iPhone 17 Pro Max. Payment settings per owner, reminders in "To pay – <Owner>" lists (created after filing, paid state synced from completion, `papertrail://bill/<id>` link back), Open Bills with copy buttons and EPC QR code (ASN's app scans it; the Rabobank app does not, 2026-11-23). Per owner "Banking app scans standard QR codes" (`bankScansEPCQRCode`); bills show a payment code from the invoice itself first (`PaymentCode`: iDEAL/Tikkie QR via Vision barcode detection, or a pay link in the PDF or its text; `PaymentCodeScanner`, searched once per bill and stored on the record). Vision's barcode detector doesn't run in the Simulator; test QR codes on a device, SEPA export (`SEPACreditTransfer`, pain.001.001.03, betalingskenmerk as structured CUR reference). **SEPA upload is untested:** the user's Rabobank business banking version has no file import either, so all owners currently pay by QR code. Test the file at a bank that imports pain.001 before relying on it.
5. **Email:** ✅ Done 2026-11-23 on the Mac: tested with the user's iCloud alias setup (PDF attachment, photo, email without attachments; emails moved to "Paper Trail Processed", Inbox untouched). Own IMAP client (`IMAPSession`, `MailboxProcessor`; SASL PLAIN or LOGIN, `<name>@icloud.com` retry), MIME parsing (`EmailIntake`), HTML → A4 PDF without JavaScript or remote content, password in the data protection Keychain, menu-bar icon, check every 5 minutes by default, open at login. Deferred: opportunistic checks on iOS; skipping attachments already filed when an email fails halfway.
6. **Expense claims:** ✅ Done 2026-11-23: tested on MacBook Pro and iPhone 17 Pro Max, incl. undo of a reimbursement and Settings → Start over → Clear All Documents (Mac, to the Trash, settings kept). Personal expenses that a company reimburses (decided 2026-11-23). Mark "To be reimbursed by <company>" when filing and later on filed documents; learned rules may remember it per sender. Overview "Expenses to claim" per company with totals (total amounts only, no VAT here). Create a claim from selected expenses: one PDF (summary page + all receipts) and a CSV for Excel/Numbers, shared via the share sheet (on the Mac also a prepared email); expenses become "Submitted". One action marks a whole claim reimbursed. Documents stay filed under their own owner. Harvest integration **deferred** by the user (2026-11-23, no direct need). API facts already checked for later (help.getharvest.com/api-v2): Personal Access Token + `Harvest-Account-Id` + required `User-Agent` with app name and a link or email; `POST /v2/expenses` (project_id, expense_category_id, spent_date, total_cost, receipt as multipart); `PATCH`/`DELETE` exist; listing expense categories needs Admin; `/v2/users/me/project_assignments` lists the user's projects. Token would go in the Keychain; receipts would leave the user's devices, so only per claim on request.
7. **VAT overview (companies only):** ← in progress (built 2026-11-23, not yet tested on devices). VAT is read with rules (`VATExtractor`), not the model: receipts often have several rates, and lines follow a fixed pattern that can be checked (VAT ≈ base × rate, or contained in a gross amount). Plan as originally written: Per company a VAT period setting (month, quarter or year). Extract VAT amount, rate (21/9/0 %) and amount excluding VAT for company documents, checked against the text like other amounts; extend the synthetic fixtures and re-run the model evaluation. Overview per company and period of input VAT to reclaim only (no sales VAT): documents with VAT, totals per rate, total to reclaim; the period is decided by the document (invoice) date, falling back to the received date. Includes personal expenses reimbursed by that company (flagged). Foreign VAT is listed separately, outside the Dutch total. Flags documents to check (VAT missing, reverse charge "BTW verlegd"). Export PDF + CSV; mark a period as submitted. The app counts; it does not decide what is deductible (general information, not tax advice; the user checks with their accountant).
8. **Design and UX:** ← in progress (proposal accepted 2026-11-23; parts a–d built (d: filing screen with the PDF beside the fields when there is room, sparkle/branch marks on suggested and rule-filled fields, payment and expense sections only when relevant, ⌘↩ to file, ⌘N to add, ⌘F to search; learned rules no longer merge senders that share an IBAN) (c: navy `AccentColor` and mint `DoneColor` in Assets.xcassets, owner colours (`OwnerColor`, automatic by position), category symbols in `Style.swift`, restyled Today cards and status labels): `RootView` with tabs on iPhone and a sidebar on iPad/Mac, `TodayView`, `ArchiveView` with search, filter chips, month groups, thumbnails (only for files already on the device) and swipe/context actions, `DocumentDetailView`, shared state in `AppModel`, Mac Settings window. Debug builds have Settings → Debug → Add Sample Documents for the Simulator). a) Navigation: tabs on iPhone (Today, Archive, Money, Settings), sidebar on Mac/iPad (Today, Review, owners, To pay, Expenses, VAT); a Today screen with what needs attention; a document detail screen (PDF, details, status, actions). b) Archive: search (sender, description, recognised text), filter chips, grouping by month, thumbnails, swipe actions. c) Look: navy accent with mint for done (from the app icon), a colour per owner, a symbol per category, status labels, friendly empty states; native iOS/macOS 26 look. d) Filing screen: PDF beside the fields on Mac/iPad, suggested values marked, sections only when relevant, keyboard shortcuts on the Mac.
9. **Polish:** ← in progress (branch `phase-9-polish`, started 2026-11-24). a) Spotlight ✅ built (`SpotlightIndexer`, `SpotlightSync`: on-device index of title, owner, category, amount and recognised text, re-indexed 2 s after changes; a result opens the document; Settings → Search turns it off and removes the index), not yet tested on devices. Still to do: searchable PDFs (invisible OCR text layer), widgets, Shortcuts actions, Face ID lock.
10. **App Store** (planned 2026-11-24; after phase 9). Goal: other people can use Paper Trail; start with the Netherlands and Belgium (EPC QR, SEPA and VAT rules are eurozone/Dutch).
    a) **Open it up for other users:** first-run setup (permissions, owners, categories) instead of built-in Company1/Company2/Private; no bank names in UI text (Rabobank/ASN only as examples in help); full use without Apple Intelligence (rules + manual filing, clear message why suggestions are missing); Dutch localisation; test the iPad layout on hardware or at least every iPad Simulator size.
    b) **Export:** Settings → Export Index writes all metadata (sender, dates, amounts, VAT lines, bill and expense state, file path) to CSV and JSON next to the archive. Needed for the exit plan and useful anyway; the PDFs themselves are already plain files.
    c) **Mac App Store:** run with App Sandbox enabled and test email (network client), Inbox folder, Share Extension, login item (`SMAppService`) and menu bar icon.
    d) **Purchases (StoreKit 2):** free tier (one owner, filing, search) and Pro (more owners, bills, expenses, VAT, email). Model still open, see Open questions. Family Sharing on. Pro features must stay usable offline; never lock the user out of their own documents.
    e) **App Store Connect (user does these):** paid Developer Program membership, app name availability, privacy policy and support URLs, privacy label ("data not collected": nothing leaves the device or the user's own iCloud), export compliance (TLS only; verify the exemption in Apple's documentation), age rating, screenshots for iPhone/iPad/Mac, description with "counts, not tax advice". Small Business Program (15 %).
    f) **TestFlight** beta with a few users before release.
    g) **Exit strategy** (build before launch, so stopping is always clean):
       - Users never depend on the app for their data: PDFs in their own iCloud Drive, bills in Apple Reminders, index exportable (b).
       - An **end-of-life switch**: one build setting/flag that unlocks all Pro features for everyone and hides purchases. Retiring = ship one final update with it on.
       - Retirement steps: final update (all features free) → stop subscription renewals in App Store Connect (verify the exact steps then; removing the app from sale may not stop them) → announce in the app and on the support page with a link to Export → remove from sale. Options instead of retiring: transfer the app to another developer (App Store Connect app transfer) or publish the code as open source.
       - Store text and terms promise: "If development stops, all features become free." Have terms, refunds and EU consumer law checked by a lawyer before launch (general information only so far).
       - Ask the user to check employment terms on side projects/IP with Starware HR or legal before launch.

Finish and test one phase before starting the next. Commit in small, working steps.

## Open questions (ask the user, don't assume)

- Pricing for the App Store (phase 10)? Discussed 2026-11-24, not decided: free download + Pro, either a subscription (about €3.99/month or €29.99/year, optional lifetime €69–79) or a one-time purchase per major version (about €29–39). One-time purchase fits limited update time better. Check competitors' current prices first.
- ~~How well does the on-device model handle Dutch?~~ First test 2026-11-23 (macOS 27.0.1, 10 synthetic docs, `PAPERTRAIL_MODEL_EVAL=1 swift test --filter ModelEvaluation`): Dutch is officially supported and reads well (amounts 10/10, sender 9/10, document date 9/10). Weak spots are judgement, not language: it invents due dates (3/10), treats direct debits as unpaid and takes the recipient's own IBAN, and files receipts as invoices. Rules in `ExtractionChecks` now validate the output against the text (2026-11-23: with checks 10/10 on every field except category 8 and reference 9). Remaining misses: a direct-debit year statement filed as Tax, a bank letter as Letters. Re-run the evaluation after each change. Real-document test on Mac and iPhone (2026-11-23) went well; two misses there led to fixes: a shop receipt saying "te betalen" (receipt check) and a "binnen 14 dagen" payment term (due date = document date + term). Apple Intelligence on iPhone needs the device and Siri languages to match.
- ~~Which devices does the user have?~~ Answered 2026-11-22: MacBook Pro M4 Max and iPhone 17 Pro Max, both with Apple Intelligence support. No iPad mentioned yet; keep the iPad layout working, but it is untested on hardware.
- ~~One "To pay" list or one per owner?~~ Answered 2026-11-23: one per owner.
- ~~Direct-debit bills: a "check the debit" reminder, or none?~~ Answered 2026-11-23: none.
- ~~Keep the original email next to the PDF?~~ Answered 2026-11-23: no, PDF only.
- ~~Dedicated mailbox: iCloud+ address or own domain?~~ Answered 2026-11-23: iCloud+ address.
