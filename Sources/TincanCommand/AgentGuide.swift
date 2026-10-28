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

        To keep working while the person is still leaving notes, run `tincan watch` in the background
        and handle each note as it arrives.
        """
}
