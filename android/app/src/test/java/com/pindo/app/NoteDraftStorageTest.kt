package com.pindo.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NoteDraftStorageTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun largeNoteAndUtf16SelectionRoundTripThroughAtomicFileWithATinyBundleToken() {
        val directory = temporary.newFolder("drafts")
        val files = AtomicNoteDraftFiles(directory)
        val handle = NoteDraftHandle(files)
        val text = "中文🙂备注\n".repeat(180_000)
        val value = NoteDraft(text, 4, text.length - 1)
        val token = handle.save(value)
        assertTrue(token.length < 160)
        assertFalse(token.contains("备注"))
        assertNull(handle.error)
        val recreated = NoteDraftHandle(files)
        assertEquals(value, recreated.restore(token))
        assertNull(recreated.error)
        assertEquals(1, directory.listFiles()!!.size)
        // Merely recreating/restoring an editor never deletes its unsubmitted draft.
        assertTrue(directory.listFiles()!!.single().exists())
        assertTrue(recreated.clear())
        assertTrue(directory.listFiles()!!.isEmpty())
    }

    @Test fun interruptedAtomicWriteKeepsThePreviousDraftAndReturnsARestorableFailureMarker() {
        val directory = temporary.newFolder("drafts")
        var fail = false
        val files = AtomicNoteDraftFiles(directory) { if (fail) throw IOException("simulated disk full") }
        val handle = NoteDraftHandle(files)
        val previous = NoteDraft("前一份完整草稿", 1, 3)
        val goodToken = handle.save(previous)
        fail = true
        val failedToken = handle.save(NoteDraft("未能落盘的新草稿", 2, 2))
        assertTrue(failedToken.endsWith(":failed"))
        assertNotNull(handle.error)
        val restored = NoteDraftHandle(files)
        assertEquals(previous, restored.restore(failedToken))
        assertNotNull(restored.error)
        assertEquals(previous, NoteDraftHandle(files).restore(goodToken))
    }

    @Test fun invalidOrTamperedDraftsFailSafelyAndRetainTheOriginalFile() {
        val directory = temporary.newFolder("drafts")
        val files = AtomicNoteDraftFiles(directory)
        val handle = NoteDraftHandle(files)
        val token = handle.save(NoteDraft("尚未提交的草稿", 0, 0))
        val file = directory.listFiles()!!.single()
        val value = JSONObject(file.readText()).put("selectionEnd", 10_000)
        file.writeText(value.toString())
        val restored = NoteDraftHandle(files)
        assertNull(restored.restore(token))
        assertNotNull(restored.error)
        assertTrue(file.exists())
        // A failure token relaxes only the last-write digest, never structure or indices.
        assertNull(restored.restore(token.removeSuffix(":ok") + ":failed"))
        assertTrue(file.exists())
        file.writeText(value.put("selectionEnd", 0).put("text", "被意外改写的草稿").toString())
        assertNull(restored.restore(token.removeSuffix(":ok") + ":failed"))
        assertNull(restored.restore("v1:../../outside:invalid:ok"))
        assertTrue(file.exists())
    }

    @Test fun aFailedFirstDraftWriteNeverThrowsFromTheSaverPath() {
        val files = AtomicNoteDraftFiles(temporary.newFolder("drafts")) { throw IOException("simulated write failure") }
        val handle = NoteDraftHandle(files)
        val token = handle.save(NoteDraft("原编辑器里仍保留这段文字", 0, 0))
        assertTrue(token.length < 160)
        assertTrue(token.endsWith(":failed"))
        assertNotNull(handle.error)
        val recreated = NoteDraftHandle(files)
        assertNull(recreated.restore(token))
        assertNotNull(recreated.error)
    }
}
