# Automation tab: proposal

An Automation tab in the inspector that shows what an app exposes to scripting and automation. That covers its AppleScript dictionary (and its live objects, the way Script Debugger's Explorer shows them), its Shortcuts actions (App Intents, App Shortcuts, older SiriKit intents) and its menu keyboard shortcuts. Each part has a static source (what the app declares) and, where it makes sense, a live source (what the running process actually holds).

## What was measured

On 2026-11-19 (macOS 27.2, Apple silicon, SIP on), as the user:

- **sdef files are where Info.plist says.** Music, Notes, Reminders and Calendar all have `NSAppleScriptEnabled` = true and an `OSAScriptingDefinition` naming a `.sdef` in `Contents/Resources` (`com.apple.Music.sdef`, `Notes.sdef`, `Reminders.sdef`, `iCal.sdef`).
- **App Intents metadata is plain JSON.** `Contents/Resources/Metadata.appintents/extract.actionsdata` has top-level keys `actions`, `entities`, `queries`, `enums`, `autoShortcuts`, `assistantIntents`, `assistantEntities`, `negativePhrases`, `shortcutTileColor`, `generator` and `version`. Each action carries `identifier`, `fullyQualifiedTypeName`, `parameters`, `openAppWhenRun`, `authenticationPolicy`, `isDiscoverable`, `descriptionMetadata` and `availabilityAnnotations`. Third-party apps ship the same file (Acorn, Actions, Afterglow, …).
- **A bundle's own file undercounts.** Reminders' main bundle declares 1 action (`TTROpenSmartListAppIntent`). Its widget extension has its own `Metadata.appintents`, and the rest come from frameworks.
- **Shortcuts' tools database has the full list.** `~/Library/Shortcuts/ToolKit/Tools-active` is a symlink to `Tools-prod.v80-<uuid>.sqlite` (27 MB). It opens read-only as the user with SIP on. It lists 45 App Intents for `com.apple.reminders` ("Create List", "Move Reminders", "Find Section", "Add or Remove Tags", …). The most per app: System Settings 412 (`com.apple.systempreferences`) and 225 (`com.apple.Settings`), Shortcuts' own built-in actions 387, Actions 254, Photos 79, Notes 55. `toolType` takes the values `appIntent`, `siriIntent`, `action` and `flowTool`. `visibilityFlags` takes the values 0, 2, 3, 5, 7, 13 and 15, meaning not yet decoded. `SampleInvocation` is empty on this Mac.
- **SiriKit intents are in extension Info.plists.** `RemindersIntentsExtension.appex` lists `IntentsSupported` (`INAddTasksIntent`, `INCreateTaskListIntent`, `INSnoozeTasksIntent`, …) and `IntentsRestrictedWhileLocked`. `.intentdefinition` files sit in the app and its extensions.

## 1. Scripting dictionary (AppleScript)

**Static.** `OSACopyScriptingDefinitionFromURL` (OSAKit, public) returns the sdef whatever form the app ships: an `.sdef`, an old `aete` resource, or `.scriptSuite`/`.scriptTerminology`. Parse it into suites, commands (direct parameter, named parameters, result), classes (properties with type and read-only or read/write, elements, inheritance), enumerations, and record types. Show the Info.plist flags at the top. Apps with no dictionary still respond to the standard suite events (open, print, quit), and the tab says so.

**Live: object explorer.** Send Apple Events to the running process, addressed by pid with `typeKernelProcessID`, so a quit app is never launched. Use the dictionary to know each class's element types:

- `get properties of <object>`: a record of the property values.
- `count every <element class> of <object>`: the number of children of each kind.
- `get <element class> i thru j of <object>`: the children, fetched a page at a time when their node is expanded.

The result is a lazy outline that starts at `application` and goes down through windows, documents, tracks and so on. Each property is shown with its value and type. Each node can copy its object reference (`window 1 of application "Music"`).

Constraints:

- **Permission.** Our Info.plist needs `NSAppleEventsUsageDescription`, and the hardened runtime needs `com.apple.security.automation.apple-events`. The user is asked once per target app. Show the current grant (from `TCCGrants.swift`) before the first event, and explain errAEEventNotPermitted (-1743) when it comes back.
- **Cost.** Some getters are huge or slow (`every track` in Music). Send events only on a click, give each a timeout (a few seconds), cap and page element fetches, and never refresh the explorer on the timer tick.
- **Errors per node.** Properties that fail (-1728 can't get, -1708 not understood) are shown inline on that row. One failed getter doesn't fail the node.
- Apps without a dictionary have no explorer, only the static section.

## 2. Shortcuts actions (App Intents)

**Primary source: the tools database.** Read `~/Library/Shortcuts/ToolKit/Tools-active` read-only (`?mode=ro`, so WAL readers don't block Shortcuts):

- `Tools`: `id`, `toolType`, `flags`, `visibilityFlags`, `authenticationPolicy`, `deprecationReplacementId`, `sourceActionProvider`, `sourceContainerId` → `ContainerMetadata.rowId`.
- `ContainerMetadata`: `id` (bundle id), `bundleVersion`, `teamId`, `containerType`.
- `ToolLocalizations`: `name`, `descriptionSummary`, `descriptionResult`, `descriptionRequires` per locale. Pick the user's locale, then `en`. Rows repeat per `localizationUsage`, so de-duplicate.
- `Parameters` / `ParameterLocalizations`, `Types`, `EntityProperties`, `EnumerationCases` for parameters and entities.

The schema is private and versioned (`v80` in the file name). Look columns up by name, and drop to the bundle files when a table or column is missing.

**Fallback and extra detail: bundle files.** `extract.actionsdata` from the app, every `.appex` in `PlugIns`, and its embedded frameworks. `autoShortcuts` gives App Shortcuts with their Siri phrases, which the database doesn't have here (`SampleInvocation` empty). This is also the only source for an app that Shortcuts hasn't indexed yet.

**SiriKit intents.** `IntentsSupported` and `IntentsRestrictedWhileLocked` from each extension's `NSExtensionAttributes`, listed with a "(SiriKit)" marker, plus the `.intentdefinition` files.

**The user's shortcuts that use the app.** `~/Library/Shortcuts/Shortcuts.sqlite` holds each shortcut's actions. Matching their identifiers against the app's tool ids gives "Your shortcuts that use this app". Format to be checked before building.

**Live.** Running an app's entity queries (to list its actual lists, notes, …) would go through the private `LinkServices` framework (`LNConnection`). Left for later.

## 3. Menu keyboard shortcuts

From the live app through Accessibility: walk `AXMenuBar`, reading `AXTitle`, `AXMenuItemCmdChar`, `AXMenuItemCmdVirtualKey` and `AXMenuItemCmdModifiers` for every item. `AXTreeWindow.swift` already walks AX trees. Shown as a table: menu path, shortcut, enabled.

## UI

A new inspector tab, **Automation**, with three sections:

1. **Scripting dictionary (sdef):** an outline of suites, commands, classes and enumerations, with a detail pane. An **Explore live objects** button switches to the object explorer for the selected process.
2. **Shortcuts actions (App Intents):** Actions, Entities, and App Shortcuts with their phrases, a hidden/visible badge, and parameters in the detail pane. SiriKit intents are marked, and the user's shortcuts that use the app are listed below.
3. **Menu keyboard shortcuts:** the table from Accessibility.

Labels follow "friendly phrase (Term)", e.g. "Opens the app when run (openAppWhenRun)", "Hidden from Shortcuts (visibilityFlags)".

## Phases

Phase 1 is built: `AutomationTab.swift`, `ScriptingDictionary.swift`, `AppIntentsInfo.swift`. `ProcXRay --automation <app>… [-v]` prints what the tab reads, with timings: 3–18 ms for a dictionary, 20–170 ms for the index and bundle files. Parameter types in the bundle JSON are numbered primitives; the names, inferred from the parameters that use them, are 0 String, 1 Bool, 2 Int, 7 Double, 8 Date, 10 Placemark, 11 URL, 12 AttributedString (and `intents` 12, IntentFile).

1. Static only, no permissions: sdef parsing and the dictionary outline, the tools database with the bundle-file fallback, and SiriKit intents.
2. Live object explorer over Apple Events, with the Automation permission flow. Built: `ScriptingExplorer.swift` (events, specifiers, values), `ScriptingExplorerWindow.swift` (the outline), opened by Explore Live Objects… in the tab. `ProcXRay --explore <pid> [depth]` walks it without the UI. Measured in pxr-dev on Finder, TextEdit and Reminders: `count` takes the container with the class in `kocl` (Finder refuses an every-specifier with -1700), so the reader tries that first and falls back. Finder reports its own class as `null` in `properties`, so a reported class the dictionary doesn't have is ignored. Reminders answers -1743 even with Automation allowed until the sender also has Reminders access (kTCCServiceReminders). Points and rectangles in replies are in host byte order.
3. Menu keyboard shortcuts from Accessibility, and the user's shortcuts that use the app.

## Apps without a dictionary

Measured 2026-11-19 on the host, 472 app bundles. 17 set `NSAppleScriptEnabled` with no dictionary file; for those `OSACopyScriptingDefinitionFromURL` launches the app and returns Cocoa's Standard and Text Suites plus any suite it adds at runtime (VLC, TextEdit, Script Editor, Automator). So the tab reads their dictionary only while they run. 381 declare nothing. Probed with Cocoa Standard Suite queries by raw code (`ProcXRay --ae-probe <pid>`: properties, name, version, count windows, window 1's name, count documents), Calculator (AppKit), Weather (SwiftUI), Fork (third-party AppKit) and Slack (Electron) answer every one with -1708, errAEEventNotHandled; TextEdit, as a control, answers all six. An app that doesn't declare scripting has no live objects to explore, so the explorer stays limited to apps with a dictionary.

## Open questions

- What `visibilityFlags` bits 2 and 3 (4, 8) mean. Bit 0 (1) is "offered in Shortcuts" and bit 1 (2) "offered to Siri": matched against 815 actions' bundle metadata, every `visibilityMetadata.assistantOnly` action is 2, every `isDiscoverable` = false one 0, Siri's own flow tools 2, and built-in Shortcuts actions 5, 7 or 15. Bits 2 and 3 split otherwise alike actions of one app (3, 7, 15) and follow nothing in `extract.actionsdata` (parameters, modes, platforms, protocols, summaries all checked), so the index sets them from something else. The index's `SystemToolProtocols` table names each tool's protocols in `identifier`: `assistantInvocable` (Siri can call it), `appIntentSchema.<domain>.<Name>` (an Apple Intelligence schema; the bundle's `assistantDefinedSchemas` has the public id, e.g. `mail.createDraft`), and roles such as `openEntity`, `deleteEntity`, `audioStarting`; the `protocol` column is a protobuf with the details. The tab shows all three.
- `ContainerMetadata.containerType` values, and whether frameworks' intents are attributed to the app through `attributionContainerId`.
- How `Shortcuts.sqlite` stores a shortcut's actions, and whether reading it needs Full Disk Access on 27.2.
