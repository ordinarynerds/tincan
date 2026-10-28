# How Tincan works

Tincan has two halves that never talk to each other directly. A library inside the app under review
writes notes to a folder; a command that an agent runs reads them from the same folder. The folder is
the whole interface between them, so either half can be replaced, and the agent never needs the app to
be running.

- [The whole system](#the-whole-system)
- [Packages and targets](#packages-and-targets)
- [Review mode, from start to stop](#review-mode-from-start-to-stop)
- [Leaving a note](#leaving-a-note)
- [Finding the element under the pointer](#finding-the-element-under-the-pointer)
- [Taking the screenshots](#taking-the-screenshots)
- [Coordinates](#coordinates)
- [Keys and the pointer](#keys-and-the-pointer)
- [Pins and the menu bar switch](#pins-and-the-menu-bar-switch)
- [The floating bar](#the-floating-bar)
- [Where notes are stored](#where-notes-are-stored)
- [The note on disk](#the-note-on-disk)
- [An agent working through notes](#an-agent-working-through-notes)
- [The MCP server](#the-mcp-server)
- [Threads and actors](#threads-and-actors)
- [What Tincan deliberately does not do](#what-tincan-deliberately-does-not-do)

## The whole system

```mermaid
flowchart LR
    person(["Person reviewing the app"])
    agent(["Coding agent"])

    subgraph app["The app under review (debug build)"]
        direction TB
        lib["Tincan library<br/>overlay, note sheet, pins,<br/>floating bar, menu bar switch"]
        appcode["The app's own windows<br/>and accessibility tree"]
        lib -- "hit test, draw window" --> appcode
    end

    subgraph disk[".tincan/ at the repository root"]
        direction TB
        notes["notes/#lt;id#gt;.json"]
        images["images/#lt;id#gt;-element.png<br/>images/#lt;id#gt;-window.png"]
    end

    subgraph cli["tincan executable"]
        direction TB
        command["Command<br/>list, show, resolve, reopen,<br/>delete, watch, path, agents"]
        mcp["MCPServer<br/>tincan mcp, JSON-RPC on stdio"]
    end

    person -- "point, click or drag,<br/>write a sentence" --> lib
    lib -- "writes images, then the note" --> disk
    lib -- "reads open notes every 1.5 s<br/>to draw pins" --> disk
    command <-- "reads and rewrites notes" --> disk
    mcp <-- "reads and rewrites notes" --> disk
    agent -- "runs commands" --> command
    agent -- "calls tools" --> mcp
    agent -- "edits code, rebuilds" --> appcode
```

The app and the command agree on the folder by running the same resolution rule
([Where notes are stored](#where-notes-are-stored)), not by talking to each other.

## Packages and targets

```mermaid
flowchart BT
    core["TincanCore<br/>Note, NoteStore, TincanLocation<br/>Foundation only"]
    lib["Tincan (library)<br/>AppKit, SwiftUI, ScreenCaptureKit"]
    commandlib["TincanCommand<br/>Command, MCPServer, NoteFormatter, AgentGuide<br/>Foundation, ImageIO"]
    exe["TincanCLI<br/>main.swift, product: tincan"]
    hostapp["Your app target<br/>links Tincan in Debug"]

    lib --> core
    commandlib --> core
    exe --> commandlib
    hostapp --> lib

    coretests["TincanCoreTests"] --> core
    coretests --> commandlib
    libtests["TincanTests"] --> lib
```

| Target | Product | Depends on | Holds |
|---|---|---|---|
| `TincanCore` | library `TincanCore` | Foundation | The note format, the store, the folder rule. Shared by both halves. |
| `Tincan` | library `Tincan` | `TincanCore`, AppKit, SwiftUI, ScreenCaptureKit | Everything that runs inside the app. |
| `TincanCommand` | none | `TincanCore`, ImageIO | The command and the MCP server, kept out of `main.swift` so tests can drive them. |
| `TincanCLI` | executable `tincan` | `TincanCommand` | One line: run the command with the process arguments. |

The executable target is named `TincanCLI` rather than `tincan` because macOS file systems are case
insensitive, and `Sources/tincan` would be the same folder as `Sources/Tincan`.

## Review mode, from start to stop

```mermaid
stateDiagram-v2
    [*] --> Installed: Tincan.install()
    Installed --> Waking: start() from the shortcut, the floating bar, a menu command or the menu bar switch
    Waking --> Reviewing: accessibility tree is awake, overlays attached
    Waking --> Installed: stop() before waking finished
    Reviewing --> Composing: click or drag, after the window is captured
    Composing --> Reviewing: Save Note, Cancel or Esc
    Reviewing --> PassingThrough: hold Option, or Use App in the bar
    PassingThrough --> Reviewing: release Option, or Leave Notes in the bar
    Reviewing --> Installed: Esc, Done, the shortcut again, or the menu bar switch
```

`install` creates the store, the menu bar switch and the shortcut monitor once. Each `start` creates a
fresh `ReviewSession`; `stop` tears all of it down: overlays, observers, the key monitor, the pin timer
and any open note sheet.

```mermaid
flowchart TD
    install["Tincan.install(configuration)"] --> resolve["TincanLocation.resolve<br/>using #filePath of the caller"]
    resolve --> store["NoteStore(directory)"]
    install --> status{"showsStatusItem?"}
    status -- yes --> item["StatusItem<br/>NSStatusItem"]
    install --> barq{"showsFloatingBar?"}
    barq -- yes --> bar["FloatingBar<br/>floating panel, SwiftUI controls"]
    install --> counter["5 s timer: refreshCount()<br/>open count for the bar and the switch"]
    install --> shortcut{"shortcut set?"}
    shortcut -- yes --> keymon["Local keyDown monitor<br/>toggles review mode"]
    shortcut -- "nil: the app has its own menu command" --> none["App calls Tincan.toggle()"]

    start["Tincan.start()"] --> session["ReviewSession(store, context)"]
    session --> wake["ElementReader.wake()<br/>off the main thread"]
    wake --> attach["attachOverlays()<br/>one child panel per eligible window"]
    session --> observe["Window observers<br/>became key or main: attach<br/>resized: follow<br/>will close: detach"]
    session --> monitor["Local monitor<br/>keyDown and flagsChanged"]
    session --> timer["1.5 s timer: refreshPins()"]
```

A window is eligible when it is visible, titled, at the normal level, has a content view, and is not
itself a panel. That keeps overlays off menus, popovers, the note sheet and Tincan's own panels.

## Leaving a note

```mermaid
sequenceDiagram
    actor P as Person
    participant O as OverlayView
    participant S as ReviewSession
    participant E as ElementReader
    participant C as WindowCapture
    participant N as Composer (popover)
    participant D as NoteStore

    P->>O: moves the pointer
    O->>S: hoverAt(point)
    S->>E: hit(at: screen point, in: window)
    E-->>S: element and its screen frame
    S-->>O: highlight rect and label
    O-->>P: orange outline, "Button “Save”"

    P->>O: clicks (or drags more than 4 pt)
    O->>S: clickAt(point) or region(rect)
    S->>E: hit test and viewName
    Note over S: element found: target kind element<br/>nothing found: 48 pt region around the click<br/>drag: region of the dragged rect
    S->>C: capture(window)
    Note over C: before the sheet opens,<br/>so the sheet is never in the picture
    C-->>S: Shot (CGImage, scale)
    S->>N: show popover beside the target
    P->>N: writes the note, picks the screenshot switches
    P->>N: Save Note (Command-Return)
    N->>S: Draft (text, attachElement, attachWindow)
    S->>C: crop(shot, rect) and outlined(shot, rect)
    C-->>S: PNG data
    S->>D: save(note, elementImage, windowImage)
    D-->>S: saved note with image names
    S-->>O: flash "Saved note 20261028-091502-k3f9"
    S->>S: refreshPins()
```

A click with no element under it still makes a note, on a 48 pt square around the point, so nothing
on screen is out of reach. The screenshot switches remember their last state in `UserDefaults`
(`TincanAttachElement`, `TincanAttachWindow`), and are disabled with a reason when the window could not
be captured.

## Finding the element under the pointer

SwiftUI does not build its accessibility tree until an accessibility client contacts the app. Until
then, a hit test on a SwiftUI window answers only with the `NSHostingView`. Tincan wakes it by being
that client, once, for itself.

```mermaid
flowchart TD
    start["Review mode starts"] --> wake["Task.detached:<br/>AXUIElementCopyAttributeValue(<br/>AXUIElementCreateApplication(own pid),<br/>AXFocusedWindow)"]
    wake --> note1["Main thread answers the query<br/>and SwiftUI builds its tree.<br/>No Accessibility permission needed:<br/>the app is asking about itself."]

    hover["Pointer at a screen point"] --> hit["window.accessibilityHitTest(point)"]
    hit --> isframe{"The window itself<br/>or its theme frame?"}
    isframe -- yes --> nohit["No element"]
    isframe -- no --> frame{"Has a non-empty<br/>accessibilityFrame?"}
    frame -- no --> nohit
    frame -- yes --> covers{"Covers more than 60%<br/>of the window?"}
    covers -- "yes: it is the background" --> nohit
    covers -- no --> read["Read role, subrole, role description,<br/>label, title, value, help, identifier<br/>through guarded key-value lookup"]
    read --> cell{"Is it an NSCell?"}
    cell -- yes --> control["Fill missing identifier, label, help<br/>from cell.controlView"]
    cell -- no --> same
    control --> same["Walk up to 4 parents with the same frame<br/>and fill missing names from them"]
    same --> anc["Collect up to 6 named ancestors<br/>(role, label, identifier)"]
    anc --> element["Note.Element"]

    hover --> view["frameView.hitTest(point)<br/>first class not starting with _ or NSTheme"]
    view --> viewname["View name, such as<br/>NSHostingView#lt;SettingsView#gt;"]
```

SwiftUI's accessibility nodes implement the `accessibility…` methods without declaring
`NSAccessibilityProtocol`, so every read is `responds(to:)` followed by `value(forKey:)`. A dynamic
call through `AnyObject` would send selectors to objects of the wrong type and crash.

## Taking the screenshots

```mermaid
flowchart TD
    capture["WindowCapture.capture(window)"] --> granted{"CGPreflightScreenCaptureAccess()<br/>already granted?"}
    granted -- yes --> sck["ScreenCaptureKit<br/>SCScreenshotManager.captureImage<br/>desktop-independent window filter,<br/>no cursor, no shadow"]
    sck -- "fails or window not listed" --> drawn
    sck -- ok --> shot["Shot(image, scale)"]
    granted -- no --> drawn["The window draws itself<br/>cacheDisplay of the theme frame view"]
    drawn --> shot
    shot --> crop["crop: the target plus a 16 pt margin,<br/>clamped to the image"]
    shot --> outline["outlined: whole window with a 3 pt<br/>orange rounded rectangle on the target"]
    crop --> png1["#lt;id#gt;-element.png"]
    outline --> png2["#lt;id#gt;-window.png"]
```

Tincan never asks for Screen Recording permission. A review tool that raises a privacy prompt in the
app under review changes the thing being reviewed. Without the permission the drawn picture is exact
for controls and text; materials and vibrancy can render flatter than on screen.

## Coordinates

Every rect in a note is in the window's own points, measured from its top-left corner. That is the
system a person describes ("near the top right") and the one SwiftUI layout code uses.

```mermaid
flowchart TD
    ev["NSEvent.locationInWindow<br/>panel coordinates, bottom-left"] -- "convert(_:from: nil)" --> ov["OverlayView point<br/>flipped: window top-left points"]
    ov -- "panel.convertPoint(toScreen:)" --> sc["Screen point<br/>bottom-left of the main screen"]
    sc -- "accessibilityHitTest" --> ax["Element frame in screen coordinates"]
    ax -- "Geometry.windowTopLeft(frame, in: window.frame)" --> note["Note.Target.rect<br/>window top-left points"]
    note -- "× shot.scale, y flipped for CGContext" --> px["Pixels in the screenshot"]
```

The overlay panel has exactly the window's frame and is flipped, so a point in the overlay view is
already a point in the note's coordinate system.

## Keys and the pointer

```mermaid
flowchart TD
    key["Key event in the app"] --> sc{"Matches the shortcut?<br/>(install monitor)"}
    sc -- yes --> toggle["Tincan.toggle()<br/>event swallowed"]
    sc -- no --> active{"Review mode on?"}
    active -- no --> app["Event reaches the app"]
    active -- yes --> kind{"Event type"}
    kind -- "flagsChanged" --> opt{"Option held or Use App chosen,<br/>and no note sheet open?"}
    opt -- yes --> pass["Panels ignore the mouse:<br/>clicks reach the app"]
    opt -- no --> catchm["Panels take the mouse again"]
    pass --> app
    catchm --> app
    kind -- "keyDown" --> esc{"Escape and<br/>no note sheet open?"}
    esc -- yes --> stop["Tincan.stop()<br/>event swallowed"]
    esc -- no --> app
```

The overlay panels are borderless and non-activating, so the app keeps key focus and its own
keyboard shortcuts keep working during review. Pointer events go to the panel, which is why review
clicks never press the app's buttons.

## Pins and the menu bar switch

```mermaid
sequenceDiagram
    participant T as Timer (1.5 s)
    participant S as ReviewSession
    participant D as NoteStore
    participant O as OverlayView
    participant M as StatusItem

    loop while review mode is on
        T->>S: refreshPins()
        S->>D: notes(status: open)
        D-->>S: open notes, oldest first
        S->>O: pins for notes whose window title matches,<br/>at the top-right corner of each target
        alt the open count changed
            S->>M: Tincan.notesChanged(openCount:)
            M->>M: refresh icon and count
        end
    end
    Note over M: Tincan also re-reads the count every 5 s,<br/>so a note resolved by an agent<br/>updates the count with review mode off
```

Pins are numbered across all open notes, so pin 3 in the app is the third note in `tincan list`.
Clicking or right-clicking a pin opens Copy Note ID, Mark as Resolved and Delete Note.

The menu bar switch shows `mappin.circle` when review mode is off and an orange filled
`mappin.circle.fill` when it is on, with the open count beside it. Its menu is rebuilt each time it
opens: Start or Stop Review Mode, the last eight open notes (choosing one copies its id), Copy
“tincan list” for Your Agent, Show Notes in Finder, and Show or Hide Floating Bar. `NotesMenu` builds
it, and the floating bar's notes button opens the same menu.

## The floating bar

Everything the keys do, with the pointer alone.

```mermaid
flowchart LR
    subgraph off["Review mode off"]
        direction LR
        g1["drag grip"] --- review["Review"] --- n1["notes button, open count"]
    end
    subgraph on["Review mode on"]
        direction LR
        g2["drag grip"] --- pin["orange pin"] --- seg["Leave Notes | Use App"] --- done["Done"] --- n2["notes button, open count"]
    end
    review -- "Tincan.start()" --> on
    done -- "Tincan.stop()" --> off
    seg -- "Tincan.isUsingApp" --> session["ReviewSession.usingApp<br/>panels let clicks through"]
    n1 --> menu["NotesMenu, the same menu<br/>as the menu bar switch"]
    n2 --> menu
```

```mermaid
flowchart TD
    state["ReviewState (@Observable)<br/>isActive, isUsingApp,<br/>isComposing, openCount"]
    tincan["Tincan<br/>start, stop, isUsingApp,<br/>notesChanged, composingChanged"] -- writes --> state
    state -- "SwiftUI observes" --> view["BarView"]
    tincan -- "stateChanged()" --> fit["FloatingBar.fit()<br/>resize around the bar's centre"]
    tincan -- "stateChanged()" --> item["StatusItem.refresh()"]
    view -- "buttons call" --> tincan
```

- **Its own panel.** A borderless, non-activating `NSPanel` at the floating level that can never be
  key or main, so clicking it leaves the app's window focused. Review mode only attaches overlays to
  windows that are not panels, so the bar never gets one, and window captures never include it.
- **First click works.** The hosting view and the drag area accept the first mouse, so a control works
  without bringing the bar forward first.
- **Where it sits.** Centred 12 pt below the menu bar at first, clear of the Dock and of the
  instructions along the bottom of each window. Dragging anywhere that is not a control
  moves it, and its origin is saved in `TincanFloatingBarOrigin`. A saved spot that is no longer
  fully on a screen is ignored, so unplugging a display cannot strand it.
- **When it shows.** It hides while the app is in the background and comes back with it. Hiding it
  from the notes menu is remembered in `TincanFloatingBarHidden`; Show Floating Bar in the menu bar
  switch brings it back. When the switch is off, Hide is disabled and says why, because the bar would
  be the only way back without the keyboard.
- **While a note is open.** Use App and Done are disabled and say "Finish or cancel the note first",
  because the note sheet belongs to the overlay and closing review mode would throw the words away.

## Where notes are stored

The app and the command run the same rule from different starting points: the app starts at the
source file that called `install` (`#filePath`, known at compile time), the command starts at its
current directory. In a normal checkout both arrive at the same `.tincan/`.

```mermaid
flowchart TD
    begin["TincanLocation.resolve(explicit, start)"] --> env{"TINCAN_DIR set<br/>and not empty?"}
    env -- yes --> e["$TINCAN_DIR"]
    env -- no --> ex{"Explicit directory?<br/>Configuration(directory:) or --dir"}
    ex -- yes --> x["That directory"]
    ex -- no --> walk["Walk up from start"]
    walk --> marker{"Folder holds .git<br/>(folder or worktree file)<br/>or .tincan?"}
    marker -- yes --> repo["#lt;that folder#gt;/.tincan"]
    marker -- "no, reached /" --> support["~/Library/Application Support/<br/>Tincan/#lt;bundle id#gt;"]
```

A sandboxed app cannot write into the repository, so it needs `TINCAN_DIR` pointing inside its
container, and the agent needs the same variable.

## The note on disk

```text
.tincan/
├── .gitignore                        "*"  (the folder ignores itself)
├── notes/
│   └── 20261028-091502-k3f9.json
└── images/
    ├── 20261028-091502-k3f9-element.png
    └── 20261028-091502-k3f9-window.png
```

```mermaid
classDiagram
    direction LR
    class Note {
        Int schema = 1
        String id
        Date created
        Status status
        String text
        Dictionary~String, String~ context
        Optional~Resolution~ resolution
    }
    class Status {
        <<enumeration>>
        open
        resolved
    }
    class AppInfo {
        Optional~String~ bundleID
        String name
        Optional~String~ version
        Optional~String~ build
    }
    class WindowInfo {
        String title
        Optional~String~ identifier
        Size size
        Double scale
    }
    class Target {
        Kind kind
        Rect rect
        Optional~String~ view
    }
    class Kind {
        <<enumeration>>
        element
        region
    }
    class Element {
        String role
        String subrole
        String roleDescription
        String label
        String title
        String value
        String help
        String identifier
    }
    class Ancestor {
        String role
        String label
        String identifier
    }
    class Images {
        Optional~String~ element
        Optional~String~ window
    }
    class Resolution {
        Date at
        Optional~String~ summary
    }
    class Rect {
        Double x
        Double y
        Double width
        Double height
    }

    Note --> Status
    Note --> AppInfo : app
    Note --> WindowInfo : window
    Note --> Target : target
    Note --> Images : images
    Note --> Resolution
    Target --> Kind
    Target --> Rect
    Target --> Element : element (optional)
    Element --> Ancestor : ancestors, up to 6
```

Every `Element` field is optional; a SwiftUI shape with no label may carry only a role. Ids are
`yyyyMMdd-HHmmss-xxxx` in UTC, so they sort by time and can be typed by their last four characters.

Writes are ordered and atomic so the two halves never need a lock:

```mermaid
sequenceDiagram
    participant A as App (writer)
    participant F as .tincan/
    participant G as Agent (reader and resolver)

    A->>F: prepare(): notes/, images/, .gitignore
    A->>F: images/#lt;id#gt;-element.png (atomic)
    A->>F: images/#lt;id#gt;-window.png (atomic)
    A->>F: notes/#lt;id#gt;.json (atomic, last)
    Note over F: a reader that sees the note<br/>is guaranteed to see its images
    G->>F: read every notes/*.json, skip files that do not decode
    G->>F: rewrite notes/#lt;id#gt;.json with status resolved (atomic)
    Note over A,G: one file per note: the app adding a note and<br/>the agent resolving another never touch the same file
```

## An agent working through notes

```mermaid
sequenceDiagram
    actor P as Person
    participant App as App with Tincan
    participant F as .tincan/
    participant Ag as Agent
    participant Code as Source code

    P->>App: leaves notes in review mode
    App->>F: writes notes and screenshots
    Ag->>F: tincan list (or tincan_list_notes)
    F-->>Ag: open notes, oldest first
    loop each note
        Ag->>F: tincan show id (or tincan_get_note)
        F-->>Ag: fields and screenshots
        Ag->>Code: search the identifier, then the label<br/>(and string catalogs), then the view name
        Ag->>Code: fix the cause, everywhere it appears
        Ag->>App: rebuild, run, look at the result
        Ag->>F: tincan resolve id -m "what changed"
    end
    App->>App: next pin refresh removes resolved pins
    P->>App: sees the fixes, reopens a note if one did not hold
```

`tincan watch` polls the folder and prints each new open note as it appears, so an agent can work
while the person is still reviewing.

## The MCP server

`tincan mcp` speaks the Model Context Protocol over stdio: one JSON-RPC message per line on stdin,
one reply per line on stdout, nothing else on stdout. It is written by hand on Foundation so the
package keeps no dependencies.

```mermaid
sequenceDiagram
    participant C as MCP client
    participant S as tincan mcp
    participant D as NoteStore

    C->>S: initialize (protocolVersion)
    S-->>C: echoed version if supported, else 2025-06-18<br/>capabilities.tools, serverInfo, instructions
    C->>S: notifications/initialized
    Note over S: notifications get no reply
    C->>S: tools/list
    S-->>C: four tools with schemas and annotations
    C->>S: tools/call tincan_list_notes {status, limit, offset}
    S->>D: notes(status:)
    S-->>C: text page plus structuredContent<br/>{total, count, offset, has_more, next_offset, notes}
    C->>S: tools/call tincan_get_note {id}
    S->>D: note(matching:), imageURL
    S-->>C: text, then each screenshot as an image block,<br/>scaled to 1200 px (element) and 1600 px (window)
    C->>S: tools/call tincan_resolve_note {id, summary}
    S->>D: resolve(id, summary)
    S-->>C: "Resolved id"
```

```mermaid
flowchart TD
    line["A line on stdin"] --> blank{"Blank?"}
    blank -- yes --> skip["Skip"]
    blank -- no --> parse{"Valid JSON object?"}
    parse -- no --> perr["-32700 parse error, id null"]
    parse -- yes --> method{"Has a method?"}
    method -- no --> inv["-32600 invalid request<br/>(no reply without an id)"]
    method -- yes --> idq{"Has an id?"}
    idq -- "no: a notification" --> silent["No reply"]
    idq -- yes --> route{"Method"}
    route -- initialize --> init["Version, capabilities, instructions"]
    route -- ping --> pong["Empty result"]
    route -- "tools/list" --> list["Tool definitions"]
    route -- "tools/call" --> known{"Known tool?"}
    known -- no --> unknown["-32602 unknown tool"]
    known -- yes --> run["Run the tool"]
    run --> ok["result.content"]
    run -- "bad arguments, note not found,<br/>ambiguous id, empty summary" --> toolerr["result.isError = true<br/>with a message that says what to do next"]
    route -- other --> nf["-32601 method not found"]
```

| Tool | Read only | Arguments | Returns |
|---|---|---|---|
| `tincan_list_notes` | yes | `status` open, resolved or all; `limit` 1 to 100; `offset` | A page of notes as text and as structured content |
| `tincan_get_note` | yes | `id`; `include_images` | The full note and both screenshots as images |
| `tincan_resolve_note` | no | `id`; `summary` (required) | Confirmation |
| `tincan_reopen_note` | no | `id` | Confirmation |

Protocol mistakes (unknown method, unknown tool) are JSON-RPC errors. Mistakes an agent can correct
(a wrong id, a missing summary) are tool results with `isError`, so the model reads the message and
tries again. Deleting is not offered over MCP; an agent should not be able to throw a note away.

## Threads and actors

```mermaid
flowchart LR
    subgraph main["@MainActor"]
        tincan["Tincan"]
        session["ReviewSession"]
        overlay["OverlayView"]
        reader["ElementReader"]
        capture["WindowCapture"]
        status["StatusItem"]
        bar["FloatingBar, BarView"]
        state["ReviewState"]
        composer["Composer (SwiftUI)"]
    end
    subgraph bg["Off the main thread"]
        wake["Task.detached: the wake query"]
        sck["ScreenCaptureKit work<br/>awaited from the main actor"]
    end
    subgraph any["Sendable, any thread"]
        store["NoteStore"]
        note["Note"]
        location["TincanLocation"]
    end
    subgraph proc["Separate process"]
        cli["tincan / tincan mcp<br/>single-threaded loop"]
    end
    session --> wake
    capture --> sck
    session --> store
    cli --> store
```

Everything that touches AppKit is on the main actor. The wake query has to run off it: it is a
question the main thread must answer, so asking from the main thread would wait on itself. AppKit
callbacks (notifications, event monitors, timers) arrive on the main queue and enter the actor with
`MainActor.assumeIsolated`, extracting non-Sendable values such as `NSEvent` fields first.

## What Tincan deliberately does not do

| Not done | Why |
|---|---|
| Ask for Accessibility or Screen Recording permission | A prompt in the app under review changes what is being reviewed. Both features work without it. |
| Change the app's view hierarchy | The overlay is a separate child window; removing it leaves the app exactly as it was. |
| Run in release builds | The host app wraps `install` in `#if DEBUG`. |
| Talk to the network | Notes stay on disk, and the folder ignores itself in git. |
| Let an agent delete notes over MCP | Deleting is for the person, in the app or the command line. |
| Depend on any package | The MCP server and everything else use Apple frameworks only. |
