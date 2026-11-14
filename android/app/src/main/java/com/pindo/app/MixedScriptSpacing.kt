package com.pindo.app

import java.text.BreakIterator
import java.util.Locale

/** UTF-16 grapheme ranges to advance at Han/Latin or Han/digit boundaries. */
internal object MixedScriptSpacing {
    const val em = 0.125f

    fun kerningRanges(text: String, verbatim: List<IntRange> = emptyList()): List<IntRange> {
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT).apply { setText(text) }
        val result = mutableListOf<IntRange>()
        var previousKind = 0
        var previousStart = 0
        var previousEnd = 0
        var previousVerbatim = false
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            val codePoint = text.codePointAt(start)
            val isVerbatim = verbatim.any { start <= it.last && end > it.first }
            val kind = when {
                Character.UnicodeScript.of(codePoint) == Character.UnicodeScript.HAN -> 1
                !text.substring(start, end).contains('\u20E3') &&
                    (Character.UnicodeScript.of(codePoint) == Character.UnicodeScript.LATIN || Character.isDigit(codePoint)) -> 2
                else -> 0
            }
            if (!(previousVerbatim && isVerbatim) && (previousKind == 1 && kind == 2 || previousKind == 2 && kind == 1)) {
                result += previousStart until previousEnd
            }
            previousKind = kind
            previousVerbatim = isVerbatim
            previousStart = start; previousEnd = end
            start = end; end = iterator.next()
        }
        return result
    }
}
