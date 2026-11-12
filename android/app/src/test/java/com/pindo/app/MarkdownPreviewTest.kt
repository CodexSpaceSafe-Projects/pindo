package com.pindo.app

import org.junit.Assert.*
import org.junit.Test

class MarkdownPreviewTest {
    @Test fun blocksRecognizeNotesChecklistsAndPreserveCodeLiterally() {
        val blocks = markdownBlocks("# 计划\n\n- [ ] 买牛奶\n- [x] 订车票\n> 记得提前\n\n```kotlin\n**not bold**\n<script>local</script>\n```\n\n2. 出发")
        assertEquals(listOf(MarkdownBlockKind.HEADING, MarkdownBlockKind.UNCHECKED, MarkdownBlockKind.CHECKED,
            MarkdownBlockKind.QUOTE, MarkdownBlockKind.CODE, MarkdownBlockKind.ORDERED), blocks.map { it.kind })
        assertEquals("**not bold**\n<script>local</script>", blocks[4].text)
        assertEquals("kotlin", blocks[4].prefix)
        assertEquals("2", blocks.last().prefix)
    }

    @Test fun unclosedFenceKeepsRemainingTextAndBlankSourceIsEmpty() {
        assertTrue(markdownBlocks(" \n\n").isEmpty())
        val block = markdownBlocks("```\n正在记录\n下一行").single()
        assertEquals(MarkdownBlockKind.CODE, block.kind)
        assertEquals("正在记录\n下一行", block.text)
    }

    @Test fun linksAndImagesAreTextAndNeverBecomeRemoteLoads() {
        val spans = markdownSpans("查看 [文档](https://example.test/private) ![封面](https://example.test/track.png)")
        assertEquals("查看 文档 [图片：封面]", spans.joinToString("") { it.text })
        assertTrue(spans.any { it.link && it.text == "文档" })
        assertFalse(spans.joinToString("") { it.text }.contains("https://"))
        assertEquals("<b>原文</b>", markdownSpans("<b>原文</b>").single().text)
    }

    @Test fun inlineCodeDoesNotInterpretMarkdownWhileTextStylesAreRetained() {
        val spans = markdownSpans("**重要** *提示* ~~旧安排~~ `**原样**`")
        assertTrue(spans.any { it.bold && it.text == "重要" })
        assertTrue(spans.any { it.italic && it.text == "提示" })
        assertTrue(spans.any { it.strike && it.text == "旧安排" })
        assertTrue(spans.any { it.code && !it.bold && it.text == "**原样**" })
    }
}
