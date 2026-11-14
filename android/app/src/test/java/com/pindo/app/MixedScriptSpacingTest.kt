package com.pindo.app

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import java.io.File
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class MixedScriptSpacingTest {
    @Test fun sharedUnicodeBoundaryVectors() {
        val vectors = generateSequence(File(System.getProperty("user.dir")).canonicalFile) { it.parentFile }
            .map { File(it, "sync-vectors/mixed-script-spacing.json") }.first { it.isFile }
        val cases = JSONArray(vectors.readText())
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val expected = case.getJSONArray("ranges")
            val ranges = (0 until expected.length()).map { expected.getJSONArray(it).let { r -> r.getInt(0) until r.getInt(0) + r.getInt(1) } }
            assertEquals(case.getString("text"), ranges, MixedScriptSpacing.kerningRanges(case.getString("text")))
        }
    }

    @Test fun displayStylingPreservesTextSelectionAndOtherStyles() {
        val source = AnnotatedString.Builder("你好abc再见").apply { addStyle(SpanStyle(fontWeight = FontWeight.Bold), 2, 5) }.toAnnotatedString()
        val display = MixedScriptVisualTransformation.filter(source)
        assertEquals(source.text, display.text.text)
        assertTrue(display.text.spanStyles.containsAll(source.spanStyles))
        for (offset in 0..source.length) {
            assertEquals(offset, display.offsetMapping.originalToTransformed(offset))
            assertEquals(offset, display.offsetMapping.transformedToOriginal(offset))
        }
        val spaces = display.text.spanStyles.filter { it.item.letterSpacing.isEm }
        assertEquals(listOf(1 until 2, 4 until 5), spaces.map { it.start until it.end })
    }

    @Test fun codeKeepsInternalAdvancesAndSurroundingTextIsSpaced() {
        val source = AnnotatedString.Builder("前abc中文def后").apply {
            addStyle(SpanStyle(fontFamily = FontFamily.Monospace), 1, 9)
        }.toAnnotatedString()
        val display = spacedText(source)
        assertEquals(source.text, display.text)
        assertEquals(listOf(0 until 1, 8 until 9), display.spanStyles.filter { it.item.letterSpacing.isEm }.map { it.start until it.end })
    }
}
