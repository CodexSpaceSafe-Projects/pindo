package com.pindo.app

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp

internal enum class MarkdownBlockKind { PARAGRAPH, HEADING, QUOTE, BULLET, ORDERED, CHECKED, UNCHECKED, CODE, DIVIDER }
internal data class MarkdownBlock(val kind: MarkdownBlockKind, val text: String, val level: Int = 0, val prefix: String = "")
internal data class MarkdownSpan(val text: String, val bold: Boolean = false, val italic: Boolean = false,
    val strike: Boolean = false, val code: Boolean = false, val link: Boolean = false)

/** Read-only local renderer. No HTML engine, URL opener, image loader, or network access. */
@Composable internal fun MarkdownPreview(markdown: String, modifier: Modifier = Modifier) {
    val blocks = remember(markdown) { markdownBlocks(markdown) }
    if (blocks.isEmpty()) {
        Column(modifier.fillMaxWidth().padding(vertical = 32.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("留一点补充，让事项更清楚", style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("可记录清单、链接、步骤或想法，支持 Markdown 格式。", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    SelectionContainer {
        Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(13.dp)) {
            for (block in blocks) {
                when (block.kind) {
                    MarkdownBlockKind.DIVIDER -> HorizontalDivider(Modifier.padding(vertical = 5.dp))
                    MarkdownBlockKind.CODE -> Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh,
                        shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (block.prefix.isNotBlank()) Text(block.prefix, style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(block.text.ifEmpty { " " }, fontFamily = FontFamily.Monospace,
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()))
                        }
                    }
                    MarkdownBlockKind.HEADING -> MarkdownText(block.text,
                        style = when (block.level) {
                            1 -> MaterialTheme.typography.headlineSmall
                            2 -> MaterialTheme.typography.titleLarge
                            else -> MaterialTheme.typography.titleMedium
                        }, modifier = Modifier.padding(top = 5.dp).semantics { heading() }, bold = true)
                    MarkdownBlockKind.QUOTE -> Row(Modifier.height(IntrinsicSize.Min)) {
                        Box(Modifier.width(3.dp).fillMaxHeight().background(MaterialTheme.colorScheme.primary, RoundedCornerShape(2.dp)))
                        MarkdownText(block.text, Modifier.padding(start = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    MarkdownBlockKind.BULLET, MarkdownBlockKind.ORDERED -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(if (block.kind == MarkdownBlockKind.BULLET) "•" else "${block.prefix}.",
                            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                        MarkdownText(block.text, Modifier.weight(1f))
                    }
                    MarkdownBlockKind.CHECKED, MarkdownBlockKind.UNCHECKED -> Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Checkbox(checked = block.kind == MarkdownBlockKind.CHECKED, onCheckedChange = null,
                            modifier = Modifier.size(24.dp))
                        MarkdownText(block.text, Modifier.weight(1f), color = if (block.kind == MarkdownBlockKind.CHECKED)
                            MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                    }
                    MarkdownBlockKind.PARAGRAPH -> MarkdownText(block.text)
                }
            }
        }
    }
}

@Composable private fun MarkdownText(source: String, modifier: Modifier = Modifier,
    style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.bodyLarge,
    color: Color = MaterialTheme.colorScheme.onSurface, bold: Boolean = false) {
    val parts = remember(source) { markdownSpans(source) }
    val primary = MaterialTheme.colorScheme.primary
    val codeBackground = MaterialTheme.colorScheme.surfaceContainerHighest
    val formatted = buildAnnotatedString {
        for (part in parts) {
            pushStyle(SpanStyle(
                color = if (part.link) primary else color,
                fontWeight = if (bold || part.bold) FontWeight.SemiBold else null,
                fontStyle = if (part.italic) FontStyle.Italic else null,
                textDecoration = when {
                    part.strike && part.link -> TextDecoration.combine(listOf(TextDecoration.LineThrough, TextDecoration.Underline))
                    part.strike -> TextDecoration.LineThrough
                    part.link -> TextDecoration.Underline
                    else -> null
                },
                fontFamily = if (part.code) FontFamily.Monospace else null,
                background = if (part.code) codeBackground else Color.Unspecified
            ))
            append(part.text)
            pop()
        }
    }
    Text(formatted, modifier, style = style)
}

/** A small source-preserving subset, deliberately not a CommonMark/HTML parser. */
internal fun markdownBlocks(source: String): List<MarkdownBlock> {
    val lines = source.replace("\r\n", "\n").replace('\r', '\n').split('\n')
    val output = mutableListOf<MarkdownBlock>()
    val paragraph = mutableListOf<String>()
    var fence: String? = null
    var language = ""
    val code = mutableListOf<String>()
    fun flushParagraph() {
        if (paragraph.isNotEmpty()) {
            output += MarkdownBlock(MarkdownBlockKind.PARAGRAPH, paragraph.joinToString("\n"))
            paragraph.clear()
        }
    }
    for (line in lines) {
        val trimmed = line.trim()
        val closingFence = fence
        if (closingFence != null) {
            if (trimmed.startsWith(closingFence)) {
                output += MarkdownBlock(MarkdownBlockKind.CODE, code.joinToString("\n"), prefix = language)
                code.clear(); fence = null
            } else code += line
            continue
        }
        val opening = fencedCode.matchEntire(trimmed)
        if (opening != null) {
            flushParagraph(); fence = opening.groupValues[1]; language = opening.groupValues[2].trim(); continue
        }
        if (trimmed.isEmpty()) { flushParagraph(); continue }
        val heading = headingLine.matchEntire(trimmed)
        val checkbox = checkboxLine.matchEntire(trimmed)
        val bullet = bulletLine.matchEntire(trimmed)
        val ordered = orderedLine.matchEntire(trimmed)
        when {
            heading != null -> { flushParagraph(); output += MarkdownBlock(MarkdownBlockKind.HEADING, heading.groupValues[2], heading.groupValues[1].length) }
            trimmed.matches(dividerLine) -> { flushParagraph(); output += MarkdownBlock(MarkdownBlockKind.DIVIDER, "") }
            trimmed.startsWith('>') -> { flushParagraph(); output += MarkdownBlock(MarkdownBlockKind.QUOTE, trimmed.removePrefix(">").trimStart()) }
            checkbox != null -> { flushParagraph(); output += MarkdownBlock(if (checkbox.groupValues[1].equals("x", true)) MarkdownBlockKind.CHECKED else MarkdownBlockKind.UNCHECKED, checkbox.groupValues[2]) }
            bullet != null -> { flushParagraph(); output += MarkdownBlock(MarkdownBlockKind.BULLET, bullet.groupValues[1]) }
            ordered != null -> { flushParagraph(); output += MarkdownBlock(MarkdownBlockKind.ORDERED, ordered.groupValues[2], prefix = ordered.groupValues[1]) }
            else -> paragraph += line
        }
    }
    if (fence != null) output += MarkdownBlock(MarkdownBlockKind.CODE, code.joinToString("\n"), prefix = language)
    flushParagraph()
    return output
}

private val fencedCode = Regex("^(`{3,}|~{3,})(.*)$")
private val headingLine = Regex("^(#{1,6})\\s+(.+?)(?:\\s+#+)?$")
private val checkboxLine = Regex("^[-*+]\\s+\\[([ xX])\\]\\s*(.*)$")
private val bulletLine = Regex("^[-*+]\\s+(.+)$")
private val orderedLine = Regex("^(\\d+)[.)]\\s+(.+)$")
private val dividerLine = Regex("(?:-\\s*){3,}|(?:\\*\\s*){3,}|(?:_\\s*){3,}")
private val inlineTokens = Regex("`([^`\\n]+)`|!\\[([^]]*)\\]\\([^)\\n]*\\)|\\[([^]]+)\\]\\(([^)\\n]+)\\)|\\*\\*(.+?)\\*\\*|__(.+?)__|~~(.+?)~~|\\*([^*\\n]+)\\*|_([^_\\n]+)_")

internal fun markdownSpans(source: String, depth: Int = 0): List<MarkdownSpan> {
    if (depth >= 5) return listOf(MarkdownSpan(source))
    val output = mutableListOf<MarkdownSpan>()
    var offset = 0
    for (token in inlineTokens.findAll(source)) {
        if (token.range.first > offset) output += MarkdownSpan(source.substring(offset, token.range.first))
        val groups = token.groups
        when {
            groups[1] != null -> output += MarkdownSpan(groups[1]!!.value, code = true)
            groups[2] != null -> output += MarkdownSpan("[图片：${groups[2]!!.value.ifBlank { "未命名" }}]", italic = true)
            groups[3] != null -> output += markdownSpans(groups[3]!!.value, depth + 1).map { it.copy(link = true) }
            groups[5] != null || groups[6] != null -> output += markdownSpans((groups[5] ?: groups[6])!!.value, depth + 1).map { it.copy(bold = true) }
            groups[7] != null -> output += markdownSpans(groups[7]!!.value, depth + 1).map { it.copy(strike = true) }
            else -> output += markdownSpans((groups[8] ?: groups[9])!!.value, depth + 1).map { it.copy(italic = true) }
        }
        offset = token.range.last + 1
    }
    if (offset < source.length) output += MarkdownSpan(source.substring(offset))
    return output
}
