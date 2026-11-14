package com.pindo.app

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.em

/** Styling only: copy/paste, selection, accessibility text and saved values keep their offsets. */
internal fun spacedText(text: AnnotatedString): AnnotatedString {
    val code = text.spanStyles.filter { it.item.fontFamily == FontFamily.Monospace }.map { it.start until it.end }
    return AnnotatedString.Builder(text).apply {
        for (range in MixedScriptSpacing.kerningRanges(text.text, code)) {
            addStyle(SpanStyle(letterSpacing = MixedScriptSpacing.em.em), range.first, range.last + 1)
        }
    }.toAnnotatedString()
}

internal fun spacedText(text: String): AnnotatedString = spacedText(AnnotatedString(text))

internal object MixedScriptVisualTransformation : VisualTransformation {
    override fun filter(text: AnnotatedString) = TransformedText(spacedText(text), OffsetMapping.Identity)
}
