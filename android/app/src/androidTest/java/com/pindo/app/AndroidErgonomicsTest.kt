package com.pindo.app

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Runs against the production activity and real software keyboard on CI's
 * emulator. Accessibility bounds drive real touch events, not fixed positions. */
@RunWith(AndroidJUnit4::class)
class AndroidErgonomicsTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as Application
    private val automation get() = instrumentation.uiAutomation
    private val output get() = File(app.filesDir, "ergonomics").apply { mkdirs() }

    @Test fun captureAndEditorStayUsableAboveTheKeyboard() {
        val existing = tasks().associate { it.getString("id") to Pair(it.getString("title"), it.optString("note")) }
        val firstTitle = "键盘验收第一件事"
        val secondTitle = "键盘验收第二件事"
        assertFalse(tasks().any { it.getString("title") == firstTitle || it.getString("title") == secondTitle })
        val previousFlags = automation.serviceInfo.flags
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        val activity = instrumentation.startActivitySync(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        var finished = false
        try {
            tap("添加事项")
            await("capture keyboard must appear") { keyboardBounds() != null }
            setText("添加事项标题", firstTitle)
            assertAboveKeyboard("快速添加事项")
            screenshot("capture-keyboard")
            tap("快速添加事项")
            await("first quick capture must persist") { tasks().any { it.getString("title") == firstTitle } }
            await("capture stays open and keyboard remains visible") {
                field("添加事项标题")?.let { it.text.isNullOrEmpty() } == true && clickable("关闭快速添加") != null && keyboardBounds() != null
            }
            setText("添加事项标题", secondTitle)
            assertAboveKeyboard("快速添加事项")
            tap("快速添加事项")
            await("second quick capture must persist without closing") {
                tasks().count { it.getString("title") == secondTitle } == 1 && clickable("关闭快速添加") != null
            }
            tap("关闭快速添加")
            await("capture closes before opening the task") { clickable("关闭快速添加") == null && keyboardBounds() == null }
            tap(firstTitle, textContains = true)
            await("reader must open") { clickable("编辑") != null && clickable("关闭编辑") != null }
            screenshot("reader")
            tap("编辑")
            await("editor keyboard must appear") { keyboardBounds() != null && field("事项备注，支持 Markdown") != null }
            val note = "真实键盘上方的保存操作，必须保留这段备注。"
            setText("事项备注，支持 Markdown", note)
            assertAboveKeyboard("保存")
            tap("预览")
            await("reading preview must hide the keyboard") { keyboardBounds() == null && clickable("继续编辑") != null }
            tap("继续编辑")
            await("returning to writing restores the keyboard and note") { keyboardBounds() != null && normal(field("事项备注，支持 Markdown")?.text) == normal(note) }
            assertAboveKeyboard("保存")
            screenshot("editor-keyboard")
            tap("保存")
            await("editor save must reach SQLite and close the editor") {
                clickable("关闭编辑") == null && keyboardBounds() == null && tasks().singleOrNull { it.getString("title") == firstTitle }?.optString("note") == note
            }
            screenshot("editor-saved")
            val after = tasks()
            assertEquals("Capture must not create duplicate or partial tasks", existing.size + 2, after.size)
            existing.forEach { (id, content) ->
                val task = after.single { it.getString("id") == id }
                assertEquals("Existing task title changed", content.first, task.getString("title"))
                assertEquals("Existing task note changed", content.second, task.optString("note"))
            }
            finished = true
        } finally {
            if (!finished) {
                screenshot("failure")
                File(output, "failure-hierarchy.txt").writeText(hierarchy())
            }
            instrumentation.runOnMainSync { activity.finish() }
            automation.serviceInfo = automation.serviceInfo.apply { flags = previousFlags }
        }
    }

    private fun tasks(): List<JSONObject> {
        val array = DocumentStorage(app).read().getJSONArray("tasks")
        return (0 until array.length()).map(array::getJSONObject)
    }

    private fun normal(text: CharSequence?): String = text?.filterNot { it.isWhitespace() || it == '\u200B' }?.toString().orEmpty()
    private fun matches(node: AccessibilityNodeInfo, label: String, textContains: Boolean): Boolean =
        normal(node.contentDescription) == normal(label) || normal(node.text) == normal(label) ||
            (textContains && normal(node.text).contains(normal(label)))

    private fun nodes(): List<AccessibilityNodeInfo> {
        val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
        automation.windows.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }.sortedByDescending { it.layer }
            .mapNotNull { it.root }.forEach(queue::add)
        val result = mutableListOf<AccessibilityNodeInfo>()
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            result.add(node)
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::add)
        }
        return result
    }

    private fun clickable(label: String, textContains: Boolean = false): AccessibilityNodeInfo? {
        val candidates = nodes().filter { it.isVisibleToUser && matches(it, label, textContains) }
        candidates.firstOrNull { it.isClickable && it.isEnabled }?.let { return it }
        for (node in candidates) {
            var parent = node.parent
            while (parent != null) {
                if (parent.isClickable && parent.isEnabled && parent.isVisibleToUser) return parent
                parent = parent.parent
            }
        }
        return null
    }

    private fun field(description: String): AccessibilityNodeInfo? = nodes().firstOrNull {
        it.isVisibleToUser && it.isEditable && normal(it.contentDescription).contains(normal(description))
    }

    private fun setText(description: String, text: String) {
        await("editable field $description") { field(description) != null }
        val node = requireNotNull(field(description))
        val arguments = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) }
        assertTrue("Text field must accept Android's native set-text action", node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments))
        await("text is visible in $description") { normal(field(description)?.text) == normal(text) }
    }

    private fun bounds(node: AccessibilityNodeInfo): Rect = Rect().also(node::getBoundsInScreen)
    private fun keyboardBounds(): Rect? = automation.windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        ?.let { Rect().also(it::getBoundsInScreen) }?.takeUnless { it.isEmpty }

    private fun assertAboveKeyboard(label: String) {
        await("$label must be touchable above the software keyboard") {
            val button = clickable(label) ?: return@await false
            val keyboard = keyboardBounds() ?: return@await false
            val area = bounds(button)
            !area.isEmpty && area.bottom <= keyboard.top
        }
        val button = bounds(requireNotNull(clickable(label)))
        val minimum = (48 * app.resources.displayMetrics.density).toInt()
        assertTrue("Primary action must retain a 48dp touch target: $button", button.width() >= minimum && button.height() >= minimum)
    }

    private fun tap(label: String, textContains: Boolean = false) {
        await("visible enabled action $label") { clickable(label, textContains) != null }
        val area = bounds(requireNotNull(clickable(label, textContains)))
        assertFalse("Cannot tap an empty target for $label", area.isEmpty)
        val time = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, area.exactCenterX(), area.exactCenterY(), 0)
        down.source = InputDevice.SOURCE_TOUCHSCREEN
        try { assertTrue("Touch down must be delivered", automation.injectInputEvent(down, true)) } finally { down.recycle() }
        val up = MotionEvent.obtain(time, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, area.exactCenterX(), area.exactCenterY(), 0)
        up.source = InputDevice.SOURCE_TOUCHSCREEN
        try { assertTrue("Touch up must be delivered", automation.injectInputEvent(up, true)) } finally { up.recycle() }
        instrumentation.waitForIdleSync()
    }

    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 15_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        fail("Timed out waiting for $description\n" + hierarchy())
    }

    private fun screenshot(name: String) {
        val bitmap = requireNotNull(automation.takeScreenshot()) { "Android could not capture the real screen" }
        try {
            File(output, "$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }

    private fun hierarchy(): String = buildString {
        automation.windows.forEach { window ->
            append("window type=").append(window.type).append(" bounds=").append(Rect().also(window::getBoundsInScreen)).append('\n')
        }
        nodes().filter { it.isVisibleToUser }.forEach { node ->
            append(node.className).append(" text=").append(if (node.isPassword) "<hidden>" else node.text)
                .append(" description=").append(node.contentDescription).append(" bounds=").append(bounds(node)).append('\n')
        }
    }
}
