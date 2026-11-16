package com.pindo.app

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.material3.Surface
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowDialog
import org.json.JSONArray

/** Runs real Compose layout and input in Robolectric; it is not a phone/emulator acceptance test. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AndroidUiTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var store: AppStore
    private lateinit var rootView: View

    @Before fun resetLocalData() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.noBackupFilesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.getSharedPreferences("pindo.preferences", Application.MODE_PRIVATE).edit().clear().commit()
        store = AppStore(app)
    }

    @Test fun dashboardCalendarAndFilteredBatchCompletion() {
        var parentID = ""
        var selectedChildID = ""
        compose.runOnUiThread {
            seedTasks()
            parentID = store.state.value.tasks.first { it.title == "准备下一版产品计划" }.id
            selectedChildID = store.state.value.tasks.first { it.title == "梳理用户反馈" }.id
        }
        showApp()
        compose.onNodeWithTag("dashboard").assertExists()
        saveScreenshot("dashboard-light")
        compose.onNodeWithTag("dashboard").performScrollToNode(hasText("准备下一版产品计划"))
        val parentTitleLeft = compose.onNodeWithText("准备下一版产品计划", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.left
        compose.onNodeWithTag("dashboard").performScrollToNode(hasText("梳理用户反馈"))
        val childTitleLeft = compose.onNodeWithText("梳理用户反馈", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.left
        assertTrue("Child titles must be visibly indented after their parent titles", childTitleLeft > parentTitleLeft)

        navigate("日历")
        compose.onNodeWithTag("calendar-day-${LocalDate.now()}").performClick()
        compose.onNodeWithTag("calendar").assertExists()
        saveScreenshot("calendar-light")
        compose.onNodeWithContentDescription("展开月历").performClick()
        compose.onNodeWithTag("calendar-day-${LocalDate.now().withDayOfMonth(LocalDate.now().lengthOfMonth())}").assertExists()
        saveScreenshot("calendar-month")
        compose.onNodeWithContentDescription("收起月历").performClick()

        navigate("管理")
        compose.onNode(hasSetTextAction()).performTextReplacement("梳理用户反馈")
        compose.onNodeWithTag("batch-mode").performClick()
        compose.onNodeWithText("全选结果").performClick()
        compose.onNodeWithText("已选择 1 项").assertExists()
        saveScreenshot("management-batch")
        compose.onNodeWithText("完成").performClick()
        compose.runOnIdle {
            assertEquals("completed", store.state.value.tasks.first { it.id == selectedChildID }.phase)
            assertTrue(store.state.value.tasks.first { it.id == parentID }.phase != "completed")
            assertEquals("pending", store.state.value.tasks.first { it.title == "敲定下一步安排" }.phase)
        }
    }

    @Test fun settingsThemeChangesPersistAndRenderDarkDashboard() {
        compose.runOnUiThread { seedTasks() }
        showApp()
        navigate("设置")
        compose.onNodeWithText("偏好设置").assertExists()
        saveScreenshot("settings-light")
        compose.onNodeWithText("深色").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("dark", store.state.value.preferences.theme) }
        navigate("清单")
        compose.onNodeWithTag("dashboard").assertExists()
        saveScreenshot("dashboard-dark")
    }

    @Test fun editorPreviewsMarkdownAndSavesDateAndContent() {
        compose.runOnUiThread {
            check(store.addTask("整理本周的产品计划", "记录讨论结论和下一步安排。", LocalDate.now(), null, null))
        }
        showApp()
        compose.onNodeWithTag("dashboard").performScrollToNode(hasText("整理本周的产品计划"))
        compose.onNodeWithText("整理本周的产品计划").performClick()
        compose.onNodeWithTag("task-title").assertDoesNotExist()
        compose.onNodeWithTag("task-reader").assertIsDisplayed()
        saveScreenshot("task-reader", "task-editor")
        compose.onNodeWithText("编辑").performClick()
        compose.onNodeWithTag("task-title").performTextReplacement("整理下一周的产品计划")
        compose.onNodeWithContentDescription("安排事项").performClick()
        compose.onNodeWithText("明天").performScrollTo().performClick()
        compose.onNodeWithText("完成").performClick()
        compose.onNodeWithTag("task-title").performScrollTo()
        saveScreenshot("task-editor", "task-editor")
        val markdown = "# 讨论纪要\n\n**明确目标**，逐步推进。\n\n- 整理反馈\n- 安排下一次讨论"
        compose.onNodeWithTag("task-note").performScrollTo().performTextReplacement(markdown)
        compose.onNodeWithText("预览").performClick()
        compose.onNodeWithText("继续编辑").assertExists()
        saveScreenshot("note-preview", "task-editor")
        compose.onNodeWithText("保存").performClick()
        compose.runOnIdle {
            val task = store.state.value.tasks.single()
            assertEquals("整理下一周的产品计划", task.title)
            assertEquals(markdown, task.note)
            assertEquals(LocalDate.now().plusDays(1), task.day)
        }
        compose.onNodeWithTag("task-editor").assertDoesNotExist()
    }

    @Test fun largeFontLayoutKeepsNavigationAndQuickAddUsable() {
        compose.runOnUiThread { seedTasks() }
        showApp(fontScale = 1.35f)
        compose.onNodeWithTag("quick-add").assertIsDisplayed()
        compose.onNodeWithTag("quick-add").performTextInput("记录一个新的想法")
        compose.onNodeWithContentDescription("快速添加事项").performClick()
        compose.runOnIdle { assertTrue(store.state.value.tasks.any { it.title == "记录一个新的想法" }) }
        saveScreenshot("dashboard-large-font")
        navigate("日历")
        compose.onNodeWithTag("calendar").assertExists()
    }

    @Test
    @Config(qualifiers = "zh-rCN-w320dp-h640dp-port-xhdpi")
    fun narrowPhoneWithLargeFontCanAddAndReachEveryPage() {
        compose.runOnUiThread { seedTasks() }
        showApp(fontScale = 1.6f)
        compose.onNodeWithTag("navigation-bar").assertIsDisplayed()
        compose.onNodeWithTag("navigation-rail").assertDoesNotExist()
        compose.onNodeWithTag("quick-add").assertIsDisplayed()
        compose.onNodeWithTag("quick-add").performTextInput("为下周留出阅读时间")
        compose.onNodeWithContentDescription("快速添加事项").assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertTrue(store.state.value.tasks.any { it.title == "为下周留出阅读时间" })
        }
        saveScreenshot("dashboard-narrow-large-font")
        compose.onNodeWithTag("scope-filter").performScrollTo().performClick()
        compose.onNodeWithText("近 7 天").performClick()
        compose.onNodeWithTag("dashboard").performScrollToNode(hasText("安排周末散步"))
        compose.onNodeWithText("安排周末散步").assertIsDisplayed()

        navigate("日历")
        compose.onNodeWithTag("calendar").assertIsDisplayed()
        navigate("管理")
        compose.onNodeWithTag("management").assertIsDisplayed()
        navigate("设置")
        compose.onNode(hasText("设置") and hasClickAction()).assertIsSelected().assertIsDisplayed()
        compose.onNodeWithTag("add-task").assertDoesNotExist()
        navigate("清单")
        compose.onNodeWithTag("dashboard").assertIsDisplayed()
    }

    @Test
    @Config(qualifiers = "zh-rCN-w1280dp-h800dp-land-xhdpi")
    fun tabletNavigationKeepsPagesAndContentWithinReach() {
        compose.runOnUiThread { seedTasks() }
        showApp()
        compose.onNodeWithTag("navigation-rail").assertIsDisplayed()
        compose.onNodeWithTag("navigation-bar").assertDoesNotExist()
        assertContentWidth("dashboard")
        val railRight = compose.onNodeWithTag("navigation-rail").fetchSemanticsNode().boundsInRoot.right
        val contentLeft = compose.onNodeWithTag("dashboard").fetchSemanticsNode().boundsInRoot.left
        assertTrue("Tablet content must not sit underneath the navigation rail", contentLeft >= railRight)
        saveScreenshot("dashboard-tablet")

        navigate("日历")
        compose.onNodeWithTag("calendar").assertIsDisplayed()
        assertContentWidth("calendar")
        saveScreenshot("calendar-tablet")
        navigate("管理")
        compose.onNodeWithTag("management").assertIsDisplayed()
        navigate("设置")
        compose.onNode(hasText("设置") and hasClickAction()).assertIsSelected()
        compose.onNodeWithTag("add-task").assertDoesNotExist()
        navigate("清单")
        compose.onNodeWithTag("add-task").assertIsDisplayed().performClick()
        compose.onNodeWithTag("task-editor").assertIsDisplayed()
        compose.onNodeWithContentDescription("关闭编辑").performClick()
        compose.onNodeWithTag("task-editor").assertDoesNotExist()
    }

    @Test
    @Config(qualifiers = "zh-rCN-w800dp-h360dp-land-xhdpi")
    fun shortLandscapeKeepsNavigationVisible() {
        showApp()
        compose.onNodeWithTag("navigation-bar").assertIsDisplayed()
        compose.onNodeWithTag("navigation-rail").assertDoesNotExist()
        navigate("日历")
        compose.onNodeWithTag("calendar").assertIsDisplayed()
        compose.onNodeWithTag("navigation-bar").assertIsDisplayed()
        saveScreenshot("calendar-short-landscape")
        navigate("清单")
        compose.onNodeWithTag("add-task").assertIsDisplayed()
    }

    @Test
    @Config(qualifiers = "zh-rCN-w800dp-h480dp-land-xhdpi")
    fun largeFontRailCanScrollToSettingsAtMinimumHeight() {
        compose.runOnUiThread { seedTasks() }
        showApp(fontScale = 2f)
        compose.onNodeWithTag("navigation-rail").assertIsDisplayed()
        compose.onNodeWithTag("navigation-bar").assertDoesNotExist()
        compose.onNode(hasText("设置") and hasClickAction()).performScrollTo().performClick()
        compose.onNode(hasText("设置") and hasClickAction()).assertIsSelected().assertIsDisplayed()
        compose.onNodeWithTag("dashboard").assertDoesNotExist()
        saveScreenshot("navigation-rail-large-font")
    }

    @Test fun readOnlySyncChipShowsStorageErrorAndRemainsActionable() {
        var clicked = false
        compose.setContent {
            PindoTheme("light") {
                Surface {
                    PindoSyncChip(AppState(readOnly = true, syncEnabled = true, syncing = true)) { clicked = true }
                }
            }
        }
        compose.onNodeWithText("存储异常").assertIsDisplayed().assertHasClickAction().performClick()
        compose.runOnIdle { assertTrue("Storage errors must still open the relevant settings", clicked) }
    }

    @Test fun primaryTaskControlsHave48DpTargetsAndPerformTheirActions() {
        compose.runOnUiThread {
            check(store.addTask("安排一次短途散步", "", LocalDate.now(), null, null))
        }
        showApp()
        assertTouchTarget(compose.onNodeWithTag("add-task"))
        compose.onNodeWithTag("dashboard").performScrollToNode(hasText("安排一次短途散步"))
        val phase = compose.onNodeWithContentDescription("待办，点击开始")
        assertTouchTarget(phase)
        phase.performClick()
        compose.runOnIdle { assertEquals("inProgress", store.state.value.tasks.single().phase) }

        val actions = compose.onNodeWithContentDescription("事项操作")
        assertTouchTarget(actions)
        actions.performClick()
        compose.onNodeWithText("修改待办").performClick()
        compose.onNodeWithTag("task-editor").assertIsDisplayed()
        assertTouchTarget(compose.onNodeWithContentDescription("关闭编辑"))
        assertTouchTarget(compose.onNode(hasText("保存") and hasClickAction()))
    }

    @Test fun importProtectsAndRestoresLocalDocumentLargerThanExternalFileLimit() {
        compose.runOnUiThread {
            val app = ApplicationProvider.getApplicationContext<Application>()
            val largeNote = "x".repeat(BackupCodec.MAX_BYTES + 1024)
            val original = emptyDocument().put("tasks", JSONArray().put(
                TodoRules.newTask("保留完整的大备注", largeNote, LocalDate.now(), null, null, 0)))
            DocumentStorage(app).write(original)
            val restoredStore = AppStore(app)
            assertEquals(largeNote.length, restoredStore.state.value.tasks.single().note.length)
            assertTrue(restoredStore.importData(emptyDocument().toString()))
            assertTrue(restoredStore.state.value.hasLocalBackup)
            assertTrue(restoredStore.state.value.tasks.isEmpty())
            assertTrue(restoredStore.restoreBackup())
            assertEquals("保留完整的大备注", restoredStore.state.value.tasks.single().title)
            assertTrue("Local protection backup must preserve the exact note",
                largeNote == restoredStore.state.value.tasks.single().note)
        }
    }

    @Test fun restoredEditorOwnsItsLeaseBeforeForegroundSynchronizationCanStart() {
        compose.runOnUiThread {
            check(store.addTask("恢复编辑中的事项", "上次已保存的备注", LocalDate.now(), null, null))
            store.startForeground()
            assertTrue("onStart must not open the network gate", !store.networkUiReady())
            store.dismissError()
        }
        val restoration = StateRestorationTester(compose)
        restoration.setContent {
            val state by store.state.collectAsState()
            PindoTheme(state.preferences.theme) { Surface { PindoScreen(store) } }
        }
        try {
            compose.onNodeWithTag("dashboard").performScrollToNode(hasText("恢复编辑中的事项"))
            compose.onNodeWithText("恢复编辑中的事项").performClick()
            compose.onNodeWithText("编辑").performClick()
            val draft = "旋转与恢复之后仍未提交的备注"
            compose.onNodeWithTag("task-note").performScrollTo().performTextReplacement(draft)
            compose.runOnUiThread { store.stopForeground() }
            restoration.emulateSavedInstanceStateRestore()
            compose.onNodeWithTag("task-note").performScrollTo().assertTextEquals(draft)
            compose.runOnUiThread {
                store.startForeground()
                assertTrue(!store.networkUiReady())
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue("The restored editor lease survives the root SideEffect", !store.networkUiReady())
                assertEquals("上次已保存的备注", store.state.value.tasks.single().note)
                val nested = store.beginEditing()
                store.endEditing(nested)
                assertTrue("Releasing a nested editor cannot release the restored editor", !store.networkUiReady())
            }
            compose.onNodeWithContentDescription("关闭编辑").performClick()
            compose.onNodeWithText("放弃修改").performClick()
            compose.onNodeWithTag("task-editor").assertDoesNotExist()
            compose.runOnIdle { assertTrue(store.networkUiReady()) }
        } finally { compose.runOnUiThread { store.stopForeground() } }
    }

    private fun showApp(fontScale: Float = 1f) {
        compose.setContent {
            val state by store.state.collectAsState()
            val currentDensity = LocalDensity.current
            val view = LocalView.current
            SideEffect { rootView = view }
            CompositionLocalProvider(LocalDensity provides Density(currentDensity.density, fontScale)) {
                PindoTheme(state.preferences.theme) { Surface { PindoScreen(store) } }
            }
        }
    }

    private fun navigate(label: String) {
        compose.onNode(hasText(label) and hasClickAction()).performClick()
        compose.waitForIdle()
    }

    private fun assertTouchTarget(node: SemanticsNodeInteraction) {
        node.assertIsDisplayed().assertHasClickAction().assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
    }

    private fun assertContentWidth(tag: String) {
        val bounds = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
        val maximum = with(compose.density) { 840.dp.toPx() }
        assertTrue("Tablet content should remain readable instead of stretching across the screen", bounds.width <= maximum + 1f)
    }

    private fun seedTasks() {
        check(store.addGroup("工作", "#447766"))
        check(store.addGroup("生活", "#C49A68"))
        val workID = store.state.value.groups.first { it.name == "工作" }.id
        val lifeID = store.state.value.groups.first { it.name == "生活" }.id
        check(store.addTask("准备下一版产品计划", "把反馈转成清晰的下一步。", LocalDate.now(), workID, null))
        val parentID = store.state.value.tasks.first().id
        check(store.addTask("梳理用户反馈", "关注日常使用中的小问题。", LocalDate.now(), workID, parentID))
        check(store.addTask("敲定下一步安排", "", LocalDate.now(), workID, parentID))
        check(store.addTask("收尾上周遗留事项", "把没有完成的事项重新安排好。", LocalDate.now().minusDays(2), workID, null))
        check(store.addTask("为自己留一点阅读时间", "读完正在看的章节，写下一个想法。", LocalDate.now(), lifeID, null))
        check(store.addTask("安排周末散步", "", LocalDate.now().plusDays(3), lifeID, null))
    }

    private fun saveScreenshot(name: String, tag: String? = null) {
        compose.waitForIdle()
        if (tag != null) compose.onNodeWithTag(tag).assertExists()
        lateinit var image: Bitmap
        compose.runOnIdle {
            // Compose captureToImage waits for a hardware frame-commit callback
            // that Robolectric cannot deliver. Draw the actual Compose view to
            // a native Skia Canvas instead; dialogs have their own decor view.
            val view = if (tag == null) rootView else checkNotNull(
                ShadowDialog.getShownDialogs().lastOrNull { it.isShowing }?.window?.decorView)
            check(view.width > 0 && view.height > 0)
            image = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(image))
        }
        val firstPixel = image.getPixel(0, 0)
        val containsUi = (0 until image.height step 13).any { y ->
            (0 until image.width step 13).any { x -> image.getPixel(x, y) != firstPixel }
        }
        val target = File("build/reports/screenshots/$name.png")
        target.parentFile?.mkdirs()
        target.outputStream().use { stream ->
            check(image.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
        image.recycle()
        check(containsUi) { "Screenshot must contain rendered UI, not a blank surface" }
    }
}
