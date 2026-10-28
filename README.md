# Tincan

Point at anything in your running macOS app, say what is wrong with it, and hand the note to your coding agent.

Tincan adds a review mode to debug builds. Press ⌃⌥⌘T, hover, and every element lights up with its name. Click one, or drag across a region, write a sentence, and save. The note goes to `.tincan/` in your repository with everything an agent needs to find the code: the element's accessibility role, label, value and identifier, the view it lives in, where it sits in the window, the screen the app was showing, and a screenshot of the element and of the whole window.

Your agent reads notes with the `tincan` command, fixes them, and marks them resolved. Their pins disappear from the app as it does.

No screenshots to crop, no "the button on the left, no, the other one".

## Install

Add the package in Xcode (File > Add Package Dependencies) or in `Package.swift`:

```swift
.package(url: "https://github.com/ordinarynerds/tincan", from: "0.1.0")
```

Link the `Tincan` library to your app target and install it at launch, in debug builds only:

```swift
#if DEBUG
import Tincan
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Tincan.install()
        #endif
    }
}
```

For a SwiftUI `App`, call it from `init()` or from an `NSApplicationDelegateAdaptor`.

Install the command for your agent:

```sh
swift build -c release --product tincan
cp .build/release/tincan /usr/local/bin/
```

## Leaving notes

| | |
|---|---|
| ⌃⌥⌘T | Start or stop review mode |
| Hover | Outlines the element under the pointer and names it |
| Click | Note on that element |
| Drag | Note on a region, for things that are not one element: spacing, alignment, a whole layout |
| Hold ⌥ | Use the app normally while review mode stays on |
| ⌘↩ | Save the note |
| Esc | Cancel the note, or leave review mode |

The note sheet has two switches: a screenshot of the element (or region) with a margin around it, and the whole window with the target outlined. Your choice is remembered.

Notes already left show as numbered pins. Hover a pin to read it; click it to copy its id, resolve it or delete it.

A pin in the menu bar shows whether review mode is on (filled orange) and how many notes are open. Its menu starts and stops review mode, lists the latest open notes (choose one to copy its id), copies `tincan list` for your agent, and shows the notes folder in Finder. Turn it off with `Tincan.Configuration(showsStatusItem: false)`.

## Working through notes, as an agent

```sh
tincan list                       # open notes, oldest first
tincan show <id>                  # every field, with absolute paths to the images
tincan resolve <id> -m "Widened the size column so 0.1 GB of 15 GB fits"
tincan reopen <id>                # the fix did not hold
tincan delete <id>                # remove a note and its images
tincan path                       # where notes are stored
tincan watch                      # print new notes as they arrive
tincan mcp                        # serve the notes over MCP (below)
tincan agents                     # the instructions below, for your agent's context
```

An id can be shortened to any unique start or end, so `tincan show k3f9` works.

### Over MCP

`tincan mcp` serves the same notes as Model Context Protocol tools over stdio, so an agent sees the screenshots as images instead of file paths. Register it once per project:

```sh
claude mcp add tincan -- tincan mcp          # Claude Code
```

Any MCP client works the same way: the command is `tincan mcp`, run from inside the repository (or with `TINCAN_DIR` set).

| Tool | Does |
|---|---|
| `tincan_list_notes` | Open notes, oldest first. `status` (open, resolved, all), `limit`, `offset` |
| `tincan_get_note` | One note, with the element and window screenshots attached as images |
| `tincan_resolve_note` | Mark it handled, with a one-line `summary` the person will read |
| `tincan_reopen_note` | Mark it open again |

Deleting stays in the command line and the app, so an agent cannot throw a note away.

Put this in your `AGENTS.md` or `CLAUDE.md`:

```markdown
## Feedback from the running app
People leave notes on the running app with Tincan. Run `tincan agents` once to learn the workflow,
then `tincan list` to see what is open. Resolve each note with `tincan resolve <id> -m "<what changed>"`
after you have rebuilt and looked at the result.
```

A Claude Code skill is in [`skills/tincan`](skills/tincan/SKILL.md). Copy it to `.claude/skills/` in your project.

## Where notes go

1. `$TINCAN_DIR`, if set (for the app, set it in the scheme's environment variables)
2. `Tincan.Configuration(directory:)`
3. `.tincan/` at the root of the git repository containing the file that called `Tincan.install()`
4. `~/Library/Application Support/Tincan/<bundle id>/`

The third is what makes it work with no setup: a debug build knows where its source is. A sandboxed app cannot write there, so set `TINCAN_DIR` to a folder inside its container, or use the fourth.

`.tincan/` holds a `.gitignore` of its own, so notes never reach a commit unless you want them to.

Each note is a JSON file in `.tincan/notes/`, and its pictures are in `.tincan/images/`. The format is documented by [`Note.swift`](Sources/TincanCore/Note.swift) and versioned by its `schema` field.

## Helping the agent find the code

Tincan reads what your app already tells VoiceOver. The more of that is right, the less the agent has to guess, and the better your app works with VoiceOver too.

- Give important views an identifier: `.accessibilityIdentifier("settings.saveButton")`. The agent searches for it first.
- Pass context about the app's state to every note:

```swift
Tincan.install(Tincan.Configuration { [weak model] in
    ["screen": model?.currentScreen.rawValue ?? "unknown"]
})
```

- If your app has its own menu command for this, pass `shortcut: nil` and call `Tincan.toggle()` from it.

## How it works

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) has diagrams of every part: the review session, element lookup, capture, storage, the note format, the command and the MCP server.

- **Finding the element.** The app asks its own windows what is under the pointer through the AppKit accessibility API. SwiftUI only builds its accessibility tree once an accessibility client has contacted the app, so when review mode starts, Tincan asks the app one question about itself through the client API, off the main thread. That needs no Accessibility permission.
- **Screenshots.** If the app already has Screen Recording permission, ScreenCaptureKit captures the window exactly as shown. Otherwise the window draws itself into a bitmap, which needs no permission; materials and vibrancy may render flatter than on screen. Tincan never asks for a permission itself.
- **Overlay.** A transparent panel sits above each window as a child window, so it moves with it and never changes the window's own view hierarchy.
- **Nothing ships.** Everything is behind `#if DEBUG` in your code. Tincan has no dependencies and makes no network requests.

## Requirements

macOS 14 or later, Swift 6. AppKit and SwiftUI apps both work.

## Licence

Apache 2.0. See [LICENSE](LICENSE).
