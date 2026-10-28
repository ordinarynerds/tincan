public enum AgentGuide {
    public static let text = """
        # Working through Tincan notes

        Someone used the app, pointed at something, and wrote what is wrong with it. Each note records
        the words, the element they clicked (its accessibility role, label, value and identifier), where
        it sits in the window, the app's own context such as the current screen, and pictures.

        1. Run `tincan list` to see open notes, oldest first.
        2. For each note, run `tincan show <id>` and open the element image, and the window image when
           there is one. The picture is what the person saw; the element fields are how to find it in code.
        3. Find the code. Search for the identifier first, then the label or title text, then the view
           named on the `View:` line. A label is usually a localized string, so search the string catalog
           too. Use the context (for example `section: Settings`) to narrow the screen.
        4. Fix the cause the note describes, not only the pixel it points at. If the same problem exists
           elsewhere in the app, fix it there too.
        5. Rebuild, run the app, and look at the result before calling it done.
        6. Run `tincan resolve <id> -m "<one line on what changed>"`. The note's pin disappears from
           the app, and the person sees the summary if they look the note up.

        If a note is unclear, or asks for something that conflicts with another decision, leave it open
        and ask the person instead of guessing.

        A reopened note says `Reopened:` with the person's reason and the fix that did not hold, and
        `tincan show` lists its whole history of edits, resolutions and reopenings. Read both before
        starting, because the obvious fix was already tried. A person may also have rewritten the
        note since you last read it; the current words are the ones that count.

        After you resolve a note, the person checks your fix in place, and the app photographs the
        same spot as they open it: `Checked:` says whether they have. A note they send back has that
        after picture, so compare it with the element picture to see what the running app showed.

        To take notes while the person is still reviewing, listen under your name:
        `tincan watch --as <your name> --once --json` in the background. The app then offers
        "Send to <your name> now" on each note. When the command prints a note and exits, work it as
        above, then start the command again. Notes sent while you work wait for you, in order.

        When a note says something can't be selected, run `tincan check` with the app running. It
        lists elements that can't be pointed at, controls with no name, and elements that swallow
        their contents, with where each one is.

        If the `tincan_*` MCP tools are available, use them instead: `tincan_list_notes`, then
        `tincan_get_note`, which attaches the screenshots as images, then `tincan_resolve_note` with the
        same one-line summary.
        """
}
