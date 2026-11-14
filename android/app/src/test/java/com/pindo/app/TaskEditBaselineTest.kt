package com.pindo.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class TaskEditBaselineTest {
    @Test fun recreationKeepsTheOriginalFieldBaselineWithoutCopyingTheNoteIntoSavedState() {
        val note = "大备注".repeat(400_000)
        val original = Todo("11111111-1111-1111-1111-111111111111", "原标题", note, LocalDate.of(2026, 11, 14), null, null, "pending", 0L, JSONObject())
        val captured = TaskEditBaseline.capture(original)
        val saved = captured.encoded()
        assertTrue(saved.toByteArray().size < 512)
        assertFalse(saved.contains("大备注"))
        val restored = TaskEditBaseline.decode(saved)
        val changedRemotely = original.copy(title = "远端改标题", note = "远端改备注", phase = "completed")
        assertEquals("原标题", restored.task(original.id).title)
        assertEquals("pending", restored.phase)
        assertEquals(taskNoteDigest(note), restored.noteDigest)
        assertNotEquals(taskNoteDigest(changedRemotely.note), restored.noteDigest)
        assertEquals(captured, restored)
    }
}
