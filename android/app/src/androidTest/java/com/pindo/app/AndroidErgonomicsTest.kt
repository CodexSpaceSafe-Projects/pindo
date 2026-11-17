package com.pindo.app

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
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
        val firstTitle = "Keyboard capture one"
        val secondTitle = "Keyboard capture two"
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
            val note = "Keyboard editing must save this exact note."
            setText("事项备注，支持 Markdown", note)
            assertAboveKeyboard("保存")
            tap("预览")
            await("reading preview must hide the keyboard") { keyboardBounds() == null && clickable("继续编辑") != null }
            tap("继续编辑")
            await("returning to writing restores the keyboard and note") { keyboardBounds() != null && field("事项备注，支持 Markdown")?.text?.toString() == note }
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

            val parentID = after.single { it.getString("title") == firstTitle }.getString("id")
            val childTitle = "Keyboard child active"
            val siblingTitle = "Keyboard child pending"
            for (title in listOf(childTitle, siblingTitle)) {
                reveal("事项操作：$firstTitle")
                tap("事项操作：$firstTitle")
                reveal("添加子项")
                tap("添加子项")
                await("new child editor must focus its title above the keyboard") {
                    keyboardBounds() != null && field("事项标题") != null
                }
                setText("事项标题", title)
                assertAboveKeyboard("保存")
                tap("保存")
                await("child must persist under the intended parent and close its editor") {
                    clickable("关闭编辑") == null && keyboardBounds() == null &&
                        tasks().singleOrNull { it.getString("title") == title }?.optString("parentID") == parentID
                }
            }
            val children = tasks().filter { it.optString("parentID") == parentID }
            assertEquals("Exactly two child tasks must be created", 2, children.size)
            val childID = children.single { it.getString("title") == childTitle }.getString("id")
            val sibling = children.single { it.getString("title") == siblingTitle }
            val siblingID = sibling.getString("id")
            val siblingBaseline = sibling.toString()
            assertEquals("Sibling starts pending", "pending", sibling.getString("phase"))
            fun assertChildPhase(childPhase: String, parentPhase: String) {
                await("child phase $childPhase and parent aggregate $parentPhase must persist") {
                    val snapshot = tasks().associateBy { it.getString("id") }
                    snapshot[childID]?.optString("phase") == childPhase && snapshot[parentID]?.optString("phase") == parentPhase
                }
                val snapshot = tasks().associateBy { it.getString("id") }
                assertEquals("Changing one child must leave its pending sibling unchanged", siblingBaseline, snapshot.getValue(siblingID).toString())
                assertEquals("Child phase changes must preserve the parent's note", note, snapshot.getValue(parentID).getString("note"))
            }
            assertChildPhase("pending", "pending")
            reveal("开始进行：$childTitle")
            tap("开始进行：$childTitle")
            assertChildPhase("inProgress", "inProgress")
            reveal("完成事项：$childTitle")
            tap("完成事项：$childTitle")
            assertChildPhase("completed", "inProgress")
            reveal("恢复待办：$childTitle")
            await("completed child must stay visible and checked in the unfinished parent's context") {
                val control = clickable("恢复待办：$childTitle") ?: return@await false
                nodes().any { node ->
                    node.isVisibleToUser && bounds(node) == bounds(control) &&
                        ((node.isCheckable && node.isChecked) ||
                            (Build.VERSION.SDK_INT >= 30 && normal(node.stateDescription) == normal("已完成")))
                }
            }
            assertNotNull("Pending sibling remains available in the unfinished view", clickable("开始进行：$siblingTitle"))
            screenshot("child-completion-context")
            tap("恢复待办：$childTitle")
            assertChildPhase("pending", "pending")
            val finalTasks = tasks()
            assertEquals("Child creation and phase cycling must not duplicate tasks", existing.size + 4, finalTasks.size)
            assertEquals("Child operations must preserve all pre-upgrade content", existing,
                finalTasks.filter { it.getString("id") in existing }.associate {
                    it.getString("id") to Pair(it.getString("title"), it.optString("note"))
                })
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
            // UiAutomation may retain Compose's old virtual-node snapshots even
            // after the screen updates. Refresh text, actions and children alike.
            if (!node.refresh()) continue
            result.add(node)
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::add)
        }
        return result
    }

    private fun clickable(label: String, textContains: Boolean = false): AccessibilityNodeInfo? {
        val visible = nodes().filter { it.isVisibleToUser }
        val candidates = visible.filter { matches(it, label, textContains) }
        candidates.firstOrNull(::acceptsClick)?.let { return it }
        for (node in candidates) {
            var parent = node.parent
            while (parent != null) {
                if (acceptsClick(parent)) return parent
                parent = parent.parent
            }
        }
        // Compose may flatten the description and click action into peers.
        // Require one exact-bounds action target, never an arbitrary button.
        for (node in candidates) {
            val sameBounds = visible.filter { acceptsClick(it) && bounds(it) == bounds(node) }.distinct()
            if (sameBounds.size == 1) return sameBounds.single()
        }
        return null
    }

    private fun acceptsClick(node: AccessibilityNodeInfo): Boolean = node.refresh() && node.isVisibleToUser && node.isEnabled &&
        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }

    private fun field(description: String): AccessibilityNodeInfo? {
        val visible = nodes().filter { it.isVisibleToUser }
        val labels = visible.filter { normal(it.contentDescription).contains(normal(description)) }
        // Compose can expose a field's description on a child semantic node
        // while the editable action lives on its EditText ancestor.
        for (label in labels) {
            var node: AccessibilityNodeInfo? = label
            while (node != null) {
                if (node.isEditable && node.isEnabled && node.isVisibleToUser && node.refresh()) return node
                node = node.parent
            }
        }
        // Some platform accessibility trees flatten those nodes into peers.
        // Only associate an unambiguous editable node with the exact bounds
        // of the requested label; never fall back to an arbitrary text field.
        for (label in labels) {
            val sameBounds = visible.filter { it.isEditable && it.isEnabled && bounds(it) == bounds(label) }.distinct()
            if (sameBounds.size == 1 && sameBounds.single().refresh()) return sameBounds.single()
        }
        return null
    }

    private fun setText(description: String, text: String) {
        await("editable field $description") { field(description) != null }
        val node = requireNotNull(field(description))
        assertTrue("Input fixture must start empty: $description", node.text.isNullOrEmpty())
        val area = bounds(node)
        keyboardBounds()?.let { area.bottom = minOf(area.bottom, it.top) }
        tapArea(area, "text field $description")
        await("$description must receive input focus with the keyboard visible") {
            field(description)?.isFocused == true && keyboardBounds() != null
        }
        // Native key events exercise the focused editor's real input connection.
        // The virtual keyboard key map supports these ASCII fixtures on API 29/34.
        instrumentation.sendStringSync(text)
        await("exact text is visible in $description") { field(description)?.text?.toString() == text }
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
        tapArea(area, label)
    }

    private fun reveal(label: String) {
        var backwards = false
        var forwardScrolls = 0
        var backwardScrolls = 0
        var nextScrollAt = 0L
        await("action $label must appear through bounded accessibility scrolling") {
            if (clickable(label) != null) return@await true
            if (SystemClock.uptimeMillis() < nextScrollAt) return@await false
            val scrollers = nodes().filter { it.isVisibleToUser && it.isEnabled && it.isScrollable }
            fun scrollable(direction: Int) = scrollers.firstOrNull { node -> node.actionList.any { it.id == direction } }
            if (!backwards && (forwardScrolls >= 8 ||
                    (scrollable(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD) == null &&
                        scrollable(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD) != null))) backwards = true
            val direction = if (backwards) AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            val used = if (backwards) backwardScrolls else forwardScrolls
            val scroller = if (used < 8) scrollable(direction) else null
            if (scroller != null) {
                if (backwards) backwardScrolls++ else forwardScrolls++
                if (scroller.performAction(direction)) instrumentation.waitForIdleSync()
                nextScrollAt = SystemClock.uptimeMillis() + 250
            }
            // A popup can be drawn before its accessibility root is published.
            // No nodes or scroll actions means wait for the next bounded poll.
            false
        }
    }

    private fun tapArea(area: Rect, label: String) {
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
                .append(" description=").append(node.contentDescription).append(" bounds=").append(bounds(node))
                .append(" editable=").append(node.isEditable).append(" focused=").append(node.isFocused)
                .append(" accessibilityFocused=").append(node.isAccessibilityFocused)
                .append(" clickable=").append(node.isClickable)
                .append(" enabled=").append(node.isEnabled).append(" actions=").append(node.actionList).append('\n')
        }
    }
}
