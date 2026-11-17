package com.pindo.app

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.io.IOException
import java.time.LocalDate

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TaskEditorCommitTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var app: Application
    private lateinit var store: AppStore

    @Before fun resetData() {
        app = ApplicationProvider.getApplicationContext<Application>()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.noBackupFilesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.getSharedPreferences("pindo.preferences", Application.MODE_PRIVATE).edit().clear().commit()
        store = AppStore(app)
    }

    @Test fun committedNewTaskClosesEvenWhenDraftCleanupFails() {
        val title = "清理草稿失败仍只保存一份"
        val note = "完整的备注内容。\n继续保留每一行。".repeat(20)
        val directory = File(app.noBackupFilesDir, "failed-draft-cleanup")
        val files = UndeletableDraftFiles(AtomicNoteDraftFiles(directory))
        val handle = NoteDraftHandle(files)
        handle.save(NoteDraft(note, 0, 0))
        val draft = directory.listFiles()!!.single()
        lateinit var draftBefore: ByteArray

        compose.setContent {
            var open by remember { mutableStateOf(true) }
            val state by store.state.collectAsState()
            PindoTheme {
                Surface {
                    if (open) TaskEditorSheet(store, state, null, null, LocalDate.now(), draftHandle = handle,
                        onDismiss = { open = false })
                    else Text("已返回清单")
                }
            }
        }
        compose.onNodeWithTag("task-title").performTextReplacement(title)
        compose.onNodeWithTag("task-note").performScrollTo().performTextReplacement(note)
        compose.runOnIdle { draftBefore = draft.readBytes() }
        compose.onNode(hasText("保存") and hasClickAction()).performClick()
        compose.onNodeWithTag("task-editor").assertDoesNotExist()
        compose.onNodeWithText("已返回清单").assertIsDisplayed()
        compose.onAllNodes(hasText("保存") and hasClickAction()).assertCountEquals(0)
        compose.runOnIdle {
            assertEquals(1, files.deleteCalls)
            assertEquals(title, store.state.value.tasks.single().title)
            assertEquals(note, store.state.value.tasks.single().note)
            val reopened = AppStore(app)
            assertEquals(title, reopened.state.value.tasks.single().title)
            assertEquals(note, reopened.state.value.tasks.single().note)
            assertTrue(draft.exists())
            assertArrayEquals(draftBefore, draft.readBytes())
        }
    }

    @Test fun initialInputWaitsForItsWindowAndDoesNotStealFocusAfterAPickerReturns() {
        val window = TestWindowInfo()
        var focusedCallbacks = 0
        compose.setContent {
            val focus = remember { FocusRequester() }
            CompositionLocalProvider(LocalWindowInfo provides window) {
                PindoTheme {
                    Column {
                        BasicTextField("标题", {}, Modifier.heightIn(min = 48.dp).testTag("initial-input")
                            .initialInputFocus(focus, true) { focusedCallbacks++ })
                        BasicTextField("备注", {}, Modifier.heightIn(min = 48.dp).testTag("other-input"))
                    }
                }
            }
        }
        compose.onNodeWithTag("initial-input").assertIsNotFocused()
        compose.runOnIdle {
            assertEquals(0, focusedCallbacks)
            window.isWindowFocused = true
        }
        compose.onNodeWithTag("initial-input").assertIsFocused()
        compose.runOnIdle { assertEquals(1, focusedCallbacks) }
        compose.onNodeWithTag("other-input").performClick().assertIsFocused()
        compose.runOnIdle { window.isWindowFocused = false }
        compose.runOnIdle { window.isWindowFocused = true }
        compose.onNodeWithTag("other-input").assertIsFocused()
        compose.runOnIdle { assertEquals(1, focusedCallbacks) }
    }

    private class TestWindowInfo : WindowInfo {
        override var isWindowFocused by mutableStateOf(false)
    }

    private class UndeletableDraftFiles(private val files: NoteDraftFiles) : NoteDraftFiles by files {
        var deleteCalls = 0
        override fun delete(id: String) {
            deleteCalls++
            throw IOException("Injected draft cleanup failure")
        }
    }
}
