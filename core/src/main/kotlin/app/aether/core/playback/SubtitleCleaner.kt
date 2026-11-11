package app.aether.core.playback

/** Removes the notes for the hard of hearing from a subtitle line: "[door slams]", "(sighs)", "♪ song ♪", "JOHN:". */
object SubtitleCleaner {
    private val brackets = Regex("""\[[^\]\n]*]|\([^)\n]*\)|\{[^}\n]*}""")
    private val music = Regex("""[♪♫][^♪♫\n]*[♪♫]?""")
    private val speaker = Regex("""^\s*(?:-\s*)?[A-ZÀ-Ý][A-ZÀ-Ý0-9 .'\-]{1,24}:\s+""", RegexOption.MULTILINE)

    fun strip(text: String): String = text
        .replace(brackets, "")
        .replace(music, "")
        .replace(speaker, "")
        .lines().map { it.replace(Regex("[ \t]{2,}"), " ").trim() }.filter { it.isNotEmpty() && it != "-" }
        .joinToString("\n")
}
