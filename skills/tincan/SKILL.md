---
name: tincan
description: Work through feedback notes left on a running macOS app with Tincan. Use when the user says they left notes, review notes, Tincan notes, or feedback "in the app", or asks to carry on with feedback, and whenever a `.tincan/` folder exists in the repository with open notes.
---

# Tincan notes

People point at things in the running app and write what is wrong. Each note says exactly where:
the element's accessibility role, label, value and identifier, the view class, its rect in the window,
the app's own context (such as the current screen), and screenshots.

## Workflow

1. `tincan list` shows open notes, oldest first. If the command is missing, build it from the
   Tincan package (`swift build -c release --product tincan`) or read `.tincan/notes/*.json` directly.
2. For each note, `tincan show <id>`, then open the image paths it prints. The element image is what
   the person was looking at; the window image shows where it sits.
3. Find the code: search for the identifier, then the label, title or value text (also in string
   catalogs, since labels are usually localized), then the type named on the `View:` line. Use the
   context line to narrow down the screen.
4. Fix what the note means, not only the spot it points at. If the same problem appears elsewhere,
   fix it everywhere in the same change.
5. Rebuild, run the app, and look at the result.
6. `tincan resolve <id> -m "<one line: what changed>"`.

Leave a note open and ask the person when it is ambiguous or conflicts with an earlier decision.

A reopened note shows `Reopened:` with the person's reason and the fix that did not hold, and
`tincan show` lists its whole history. Read both before starting: the obvious fix was already tried.
If you reopen a note yourself, say why: `tincan reopen <id> -m "<what is still wrong>"`.

After you resolve a note, the person checks your fix in place, and the app photographs the same spot
as they open it. `tincan show` then lists an `After image:` and a `Checked:` line. A note they
reopen comes back with both, so compare the before and after pictures to see what your fix did.

To take notes while the person is still reviewing, listen under your own name, for example
`tincan watch --as Claude --once --json`, as a background command. The app then shows "Send to
Claude now" on each note. When the command prints a note and exits, work it as above, then start it
again. Notes sent while you work queue up and are handed over in order.

When a note says something can't be selected, or before fixing accessibility, run `tincan check`
with the app running: it lists elements that can't be pointed at, controls with no name, and
elements that swallow their contents, with where each one is.

If the `tincan_*` MCP tools are available, use them instead of the command: `tincan_list_notes`,
then `tincan_get_note` (it attaches both screenshots as images), then `tincan_resolve_note` with the
same one-line summary. Register them with `claude mcp add tincan -- tincan mcp`.
