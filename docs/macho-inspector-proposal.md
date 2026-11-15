# Mach-O inspector: proposal

An Inspect button next to every binary file the app shows. It opens a window that decodes everything decodable about the file, in tabs and groups. The same window opens any file from File ▸ Open Binary…, a drop, or Open With, with no process involved. Nothing here needs root or a task port: it reads the file.

## What was measured

On 2026-11-15 (macOS 27.2, Apple silicon), the executables of all running processes (`ps -axo comm=`, the absolute paths only): 593 files, 1 unreadable. Counted with throwaway Python (not in the repo), reading the fat header and every slice's load commands.

- **Fat is the norm.** 558 fat, 34 thin. 1,511 slices: arm64e 519, **arm64e_x1** (`CPU_SUBTYPE_ARM64E_X1`, 12, in the SDK next to `ARM64_X1`) 507, arm64 (ALL) 75, x86_64 407, x86_64h 3. Apple's system binaries now ship arm64e and arm64e_x1 side by side (518 and 517 fat slices), so "which slice runs here" isn't just arm64e-over-arm64: the window has to pick a slice, default to the one this Mac would run, and the ranking has to know X1. How dyld chooses between arm64e and arm64e_x1 on a given CPU is an open question below. One fat slice has a nonzero ptrauth ABI version (`0x81000002`, `remotepairingd`).
- **Sizes.** Median 0.56 MB. Largest: WhatsApp 467 MB, node 121 MB, BetterTouchTool 117 MB, ollama 78 MB, searchpartyd 61 MB. The file has to be mapped, not read, and the heavy tables (symbols, strings, fixups) decoded only when their tab is open.
- **Load commands per slice.** Median 39, max 164. Linked libraries median 21, max 147. Sections per slice max 62. Small enough to decode all of them eagerly.
- **Which load commands occur** (count over all slices): LOAD_DYLIB 26,388, LOAD_WEAK_DYLIB 12,601, SEGMENT_64 7,551, SYMTAB / DYSYMTAB / LOAD_DYLINKER / UUID / CODE_SIGNATURE 1,511 each, BUILD_VERSION 1,503, DATA_IN_CODE 1,503, SOURCE_VERSION 1,501, MAIN 1,500, FUNCTION_STARTS 1,499, DYLD_CHAINED_FIXUPS and DYLD_EXPORTS_TRIE 1,457, RPATH 722, DYLD_INFO_ONLY 54 (the older opcode fixups, so both formats are needed), DYLD_ENVIRONMENT (0x27) 24, LAZY_LOAD_DYLIB_INFO (0x3a) 35, ENCRYPTION_INFO_64 13 (4 with `cryptid` ≠ 0, i.e. encrypted), VERSION_MIN_MACOSX 8, FUNCTION_VARIANTS / FUNCTION_VARIANT_FIXUPS 2.
- **Every command seen is in the Xcode 27.2 SDK's `loader.h`**, including 0x3a, `LC_LAZY_LOAD_DYLIB_INFO` (a `linkedit_data_command`, 16 bytes, in `progressd` and `authd`) and the `dylib_use_command` form of LC_LOAD_DYLIB (a marker `0x1a741800` where the timestamp was, then flags: weak, re-export, upward, delayed init). A command the reader can't name is still shown, as raw words and bytes.
- **LC_DYLD_ENVIRONMENT is real and worth showing.** Firefox sets `DYLD_VERSIONED_FRAMEWORK_PATH=/Library/Apple…`; `AuthenticationServicesAgent` (in the App cryptex) sets `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` into `/System/Cryptexes/App/…`. It changes where libraries come from, so it belongs on the Libraries tab, not only in the raw list.
- **Platforms** (BUILD_VERSION, per slice): macOS 1,451, Mac Catalyst 37, DriverKit 11 (5 `.dext` drivers, Apple's and Karabiner's), iOS 4 (iPhone apps running on the Mac: SSHTunnel, Overcast's and mercantile's extensions, all under `/private/var/folders/…/Wrapper/`). Names come from the SDK's `PLATFORM_*` list, which runs to 24 (exclave platforms included).
- **System libraries are not files.** `/usr/lib/libSystem.B.dylib` doesn't exist; it is in the dyld shared cache (`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e` and its `.01`… subcaches). Most entries in a process's linked-library list are like this, so the first version shows them as "in the shared cache" with no Inspect button; phase 4 reads them out of the cache.
- **Cost, for scale.** The Python survey (whole files read, load commands only) took 3.34 s for all 593. `otool -lLv` on Mail: 0.04 s; `nm -m` on Mail: 41,056 lines in 0.01 s. A Swift reader over a mapped file should do the load commands of the biggest file in well under 10 ms; to be measured in phase 1 (load commands of all 593 files, and symbols of WhatsApp), not assumed.

## Where the button goes

A Mach-O is recognised by its first four bytes: `MH_MAGIC_64`, `MH_MAGIC`, `FAT_MAGIC`, `FAT_MAGIC_64` (either byte order), and `!<arch>\n` for static archives. A bundle (an `.app`, `.framework`, `.xpc`, `.appex`, `.kext`) counts as its main executable (`CFBundleExecutable`, and for a framework its `Versions/Current/<name>`). The check reads 8 bytes, cached per path and modification time, so the rows that already call `Reveal.exists` don't get slower.

The button (`InspectMachOButton`, SF symbol `doc.viewfinder`, help "Inspect binary") sits next to `RevealButton` wherever a path gets one and the path is a Mach-O:

- `PathText` and `KVValueView` (the Overview's executable path, launchd plists' `Program`, Background Items' executables).
- The process table's hover button and the info bubble (`ProcessOutline.swift`, AppKit): a second small button after the Finder one.
- File lists that already reveal: open files (`Visualizers.swift`), syscall trace paths, Origin's installed-by rows.
- Inside the inspector window itself: every linked library, rpath-resolved, opens another inspector window.

The button shows only while the path exists and is a Mach-O (or a bundle with one); unlike Reveal, a missing file has no disabled Inspect button, since there's no way left to tell it was a binary.

Also: **File ▸ Open Binary…** (⇧⌘O) with an open panel, dropping a file on the Dock icon or on an inspector window, and `open -a "Proc X-Ray" file` (the app declares it opens `public.unix-executable`, `com.apple.mach-o-binary`, `public.object-code`, `com.apple.bundle` as a viewer, never as the default).

## The window

`WindowGroup("Binary", id: MachOWindow.id, for: MachORef.self)`, like the process window: restoration disabled, no "New" command. `MachORef` is the file path plus, when opened from a process, that process (for the "running copy" check below). Title: the file name; subtitle: its folder.

Layout: a toolbar with the **slice picker** (fat files: one segment per arch, default the one this Mac would run, by the same ranking the kernel uses (`macho_best_fat_arch` / `NXFindBestFatArch`, X1 included); a translated process's x86_64 when opened from a Rosetta process), a search field that filters the current tab, and Reveal / Copy path. Below it, a sidebar of tabs, each a list of the app's existing `Card`s, so it reads like the process inspector. Every offset is shown as a file offset and, where it has one, a VM address; hovering a number shows the other.

The tabs, in order. Each lists what it decodes; empty groups are left out, not shown as "none", except where absence is the finding (no code signature, no hardened runtime).

### 1. Summary

- **File**: path, size, type (thin / fat / fat64 / archive), slices with arch, offset, size, alignment.
- **This slice**: filetype (`MH_EXECUTE`, `MH_DYLIB`, `MH_BUNDLE`, `MH_OBJECT`, `MH_DYLINKER`, `MH_KEXT_BUNDLE`, `MH_FILESET`, `MH_DSYM`…), cputype/subtype (arm64e with its ptrauth ABI version from the subtype's high bits), UUID, header flags each decoded (PIE, TWO_LEVEL, NO_HEAP_EXECUTION, APP_EXTENSION_SAFE, HAS_TLV_DESCRIPTORS, SIM_SUPPORT, DYLIB_IN_CACHE…).
- **Built for**: platform, min OS, SDK, tools (ld, swiftc, clang with versions), source version, target triple.
- **At a glance**, each a fact from the bytes: signed or not and by whom (team ID from the CodeDirectory), hardened runtime, library validation, encrypted, has Objective-C, has Swift, entry point, stripped or not, number of linked libraries (of which weak), rpaths.
- **Running copy** (opened from a process only): whether the file on disk is still the one running. The process's main image UUID comes from dyld's process info (needs a task port; through the helper) or, without one, compare the file's inode and mtime with the process's text vnode from `proc_pidinfo(PROC_PIDREGIONPATHINFO)`. "Replaced since launch" is a finding.

### 2. Load commands

Every load command in file order, one row each: index, name (or "unknown 0x…"), size, and its decoded fields, expandable. Covers every command in `loader.h` (segment, dylib family, dylinker, rpath, uuid, build/version-min, source version, main/unixthread with the register state decoded per arch, symtab/dysymtab, linkedit_data family, encryption info, linker option, note, fileset entry, sub_* commands, prebound/twolevel hints, routines, ident/fvmfile for old files) and raw words plus a hex dump for anything else. Malformed commands (size not a multiple of 8, running past `sizeofcmds`, offsets outside the file) are shown in red with what is wrong, and the rest still decode.

### 3. Segments and sections

Segments with file range, VM range, max/init protection, flags; their sections with type and attributes decoded (`S_CSTRING_LITERALS`, `S_ATTR_PURE_INSTRUCTIONS`…), alignment, relocation counts. A **file layout bar**: the file's bytes from 0 to its size, coloured by owner (header, load commands, each segment, each `__LINKEDIT` blob: fixups, exports, symtab, strings, function starts, code signature), with gaps and overlaps marked. Clicking a section opens it in the Hex tab.

### 4. Libraries

- **Linked**: every LOAD_DYLIB / WEAK / REEXPORT / UPWARD / LAZY, in load order (the ordinal symbols bind against), with current and compatibility version, and where it resolves: `@rpath`, `@executable_path`, `@loader_path` expanded against this file's rpaths and location, then "file", "in the shared cache" (looked up in the running cache's image list, `SharedCacheImages` in `StackSymbols.swift`), or "missing" (red for a strong dependency, grey for weak).
- **Rpaths** with their expansion and whether each exists.
- **dyld environment** (LC_DYLD_ENVIRONMENT) and dylinker path.
- For a dylib: its own install name, versions, and its sub_framework / allowable clients / sub_umbrella.

### 5. Symbols

Tables, filterable, demangled (Swift through `swift_demangle` from libswiftCore, C++ through `__cxa_demangle`), with the mangled name on hover:

- **Exports**: the exports trie (or `LC_DYLD_INFO` export trie), with kind (regular, thread-local, absolute), weak-def, re-export source, stub-and-resolver.
- **Imports**: what is bound, from which library ordinal (so: which library each import comes from), weak, lazy; from chained-fixup imports or the bind opcodes.
- **Symbol table**: nlist entries with type, section, description bits; debug (stab) entries grouped separately (source files, object files: a not-stripped binary names its build paths).
- **Indirect symbols** per stub / pointer section.

### 6. Fixups

Chained fixups: header, imports format, per-segment starts, pointer format, page count; counts of rebases and binds and, on demand, the list (target, addend, auth key, diversity, address-diversity for arm64e). Older binaries: the rebase, bind, weak-bind and lazy-bind opcode streams, decoded to the same list, and the opcodes themselves on request. Relocations for object files.

### 7. Code signature

Decoded from the superblob in the file, not through the Security framework (so it works on a file that isn't valid and shows why): every blob in the superblob; each CodeDirectory (version, flags such as runtime / library-validation / linker-signed / adhoc, hash type, page size, code limit, team ID, identifier, platform, exec segment flags, the runtime version, cdhash) and its special slots; the requirements set, decompiled to requirement language (the same text `codesign -d -r-` prints); entitlements as XML and as DER (and whether they agree); launch constraints (self, parent, responsible, library) decoded; the CMS blob's certificate chain (subject, issuer, validity, Apple-anchored or not). Then `SecStaticCodeCheckValidity` on the file for a verdict, shown next to, not instead of, the decode. Code that already exists for running processes (`CodeSign.swift`) stays; this tab is the file's view.

### 8. Objective-C and Swift

- **Objective-C**: classes (superclass, instance size, flags, ivars, properties, methods with type encodings decoded to C-like signatures), categories, protocols, selector references, the image info flags; small-method lists and relative method lists both.
- **Swift**: types from `__swift5_types` (kind, name, parent, generic signature), protocol conformances (`__swift5_proto`), protocols, field records (stored properties and types), associated types, and the Swift version from the image info.

### 9. Strings and constants

C strings (`__cstring`, `__oslogstring`), CFStrings, UTF-16 strings, Objective-C method names and class names, each with its address, filterable. Useful for spotting URLs, paths, bundle IDs and log formats.

### 10. Code

Function starts (count, list, sizes), data-in-code entries, unwind info (`__unwind_info` personalities, LSDA, encodings per function range) and `__eh_frame` CIE/FDE counts, entry point, init/term functions (`__mod_init_func`, `__init_offsets`), thread-local variables. No disassembler in this proposal; a function row offers "Open in Hopper" when Hopper is installed.

### 11. Hex

A hex and ASCII view of the slice, virtualised (467 MB has to scroll), with the layout bar's colours as the background of each byte range and a breadcrumb of what the selected byte belongs to (load command 12 › LC_SEGMENT_64 __DATA › section __got). Every other tab's "Show bytes" lands here.

### Other file kinds

- **Static archive** (`!<arch>`, including BSD `#1/` long names and the symbol index): a member list; each member opens as its own Mach-O.
- **MH_FILESET** (kernel collections): the fileset entries; each entry opens as an embedded Mach-O.
- **dSYM** (MH_DSYM): segments and the DWARF sections' sizes; the UUID match against the binary it's for. No DWARF decoding.
- **32-bit and old** (i386, armv7, PPC): header and load commands; the rest where it is format-independent.

## How it's built

- `Sys/MachO/` (new): a bounds-checked reader over `Data(contentsOf:options: .alwaysMapped)`. Every offset and count from the file is checked against the slice before use; a bad value becomes a finding on the row, never a trap. Structs come from the SDK's `MachO` module (`import MachO`, as `SandboxTables.swift` already does) where it has them; the undocumented ones are written out with a comment naming the source (dyld's open-source headers).
- One `MachOFile` per window, parsed on a background task: the header and load commands eagerly (milliseconds), each heavy table lazily when its tab is first shown, cached for the window's life. The window keeps no state across launches.
- Tests: a corpus test that parses every executable of the running processes and every file in `/usr/bin`, `/usr/libexec` and `/Applications/*/Contents/MacOS` and checks it never throws away a load command and matches `otool -l`'s command count and `dyldinfo`/`dyld_info -fixups` counts. A fuzz test that truncates and flips bytes in a few binaries and checks the reader never crashes.

## Phases

1. **Reader, window, buttons.** Header, slices, load commands, segments and sections, libraries with resolution, build info, summary. The button everywhere listed above, File ▸ Open, drop. Measured: parse time over the corpus and for the largest files. **Done**, see below; the "running copy" check is left for later.
2. **Symbols, fixups, code signature, strings.**
3. **Objective-C, Swift, code (unwind, function starts), hex view and layout bar.**
4. **Shared cache images**: inspect a library that is only in the dyld shared cache, read out of the cache files; archives and filesets.

## Phase 1: done

Code: `Sys/MachO/` (`MachOFile.swift` the mapped file, bounds-checked reader and every load command; `MachONames.swift`; `MachOLibraries.swift`; `MachODump.swift` the command-line checks), `UI/MachOWindow.swift`, `UI/MachOButton.swift`. Tabs: Summary (issues, file, slices, this slice, at a glance, built for, header flags, fileset entries), Commands (every load command, expandable to its decoded fields, with the offset in the file on hover), Segments (each segment and its sections), Libraries (linked libraries resolved, run paths expanded, the main executable, dylinker, dyld environment, umbrella and clients). The toolbar's slice picker marks with ✓ the slice `macho_best_slice` (dyld's own choice, from `<mach-o/utils.h>`, bound through `dlsym` since Swift's `MachO` module doesn't include that header) picks on this Mac; on this machine that is arm64e, not arm64e_x1, for Safari and `/bin/ls`. The filter field narrows commands, sections and libraries.

Where the button is: next to every `RevealButton` (so every path in the inspector, Visualizers, syscall trace and lists that already had one), on the process table's Path cell when hovered, in the info bubble, and in the row's context menu ("Inspect Binary"). File ▸ Open Binary… (⇧⌘O), drops on a binary window, and Open With / a Dock drop / `open -a` (document types in `build-app.sh`, rank Alternate).

Measured, 2026-11-15, release build:

- **Corpus**: 4,339 files (running executables, `/usr/bin`, `/usr/libexec`, `/usr/sbin`, every app's main executable, the dylibs under `/Applications`, 20 static archives), 7,922 slices, 7.98 s in all, mean 1.84 ms per file, slowest 10.6 ms. `ProcXRay --macho-corpus <list> out.tsv`.
- **Against otool**: for each of the 3,945 non-archive files otool can open (7,730 slices), the load command count, linked library count and UUID of every slice match `otool -arch all -l` exactly. (One file otool can't open: its wrapper breaks on parentheses in `1Password Helper (Renderer)`.)
- **No false alarms**: 0 issues over the corpus, after three checks were corrected: an object file's single unnamed segment holds sections naming other segments (normal), a segment with VM size 0 is in the file but never mapped (Go's `__DWARF`, e.g. Juggler), and DriverKit `.dext` executables have no entry point.
- **Damaged files**: `ProcXRay --macho-fuzz <file> 3000` changes 1 to 16 bytes in the headers (the first 64 KB, and the first 16 KB of every slice) or cuts the file short. 3,000 copies each of `/bin/ls`, Safari, `/usr/lib/dyld` and `libswiftCompatibility50.a`: no crash, 488, 484, 497 and 1,613 issues reported.
- **Opening files**: SwiftUI makes a Binary window for the first file of an open event (the scene handles `file:` URLs) and gives the app delegate only the others: 4 files opened, 3 reach `application(_:open:)`. `openWindow` calls made in quick succession drop all but the last, so `MachOOpen` spaces them 0.15 s apart. Checked with the window server's list: 4 files at launch → 4 windows; 3 more while running → 7; 2 of those again → still 7 (brought forward); a text file → an alert.

## Open questions

- Which of arm64e and arm64e_x1 dyld/the kernel loads on this Mac and on older Apple silicon (check with `vmmap`/dyld process info UUIDs against each slice's UUID), so the default slice is right rather than guessed.
- Whether the "running copy" check is worth the task-port path or the vnode comparison alone is enough.
- Whether the Inspect button should also go on the process table row itself (it has one hover button today).
