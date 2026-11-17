package com.pindo.app

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@LooperMode(LooperMode.Mode.PAUSED)
class ReadOnlyLifecycleTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var app: Application
    private lateinit var database: File
    private val damagedBytes = "Pindo unreadable database fixture; preserve these exact bytes.".toByteArray()

    @Before fun prepareUnreadableDatabase() {
        app = ApplicationProvider.getApplicationContext()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.noBackupFilesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.getSharedPreferences("pindo.preferences", Application.MODE_PRIVATE).edit().clear().commit()
        database = File(app.filesDir, "pindo.sqlite").apply { writeBytes(damagedBytes) }
    }

    @Test fun lifecycleAndNestedEditingKeepUnreadableStorageReadOnlyWithoutReopeningIt() {
        val store = AppStore(app)
        assertTrue(store.state.value.readOnly)
        repeat(2) {
            store.startForeground()
            store.markUiReady()
            assertFalse(store.networkUiReady())
            val first = store.beginEditing()
            val second = store.beginEditing()
            store.endEditing(first)
            assertFalse(store.networkUiReady())
            store.stopForeground()
            store.endEditing(second)
            assertFalse(store.networkUiReady())
        }
        assertArrayEquals(damagedBytes, database.readBytes())
    }

    @Test fun actualActivityCanOpenReadOnlySyncExplanationAndCloseWithoutLosingOriginalBytes() {
        val controller = Robolectric.buildActivity(MainActivity::class.java)
        try {
            val activity = controller.setup().visible().get()
            val store = ViewModelProvider(activity)[AppStore::class.java]
            assertTrue(store.state.value.readOnly)
            compose.onNodeWithText("存储异常").assertIsDisplayed().performClick()
            compose.onNodeWithText("云同步").performScrollTo().performClick()
            compose.onNodeWithTag("sync-read-only").assertIsDisplayed()
            compose.onNodeWithText("配对连接").assertDoesNotExist()
            compose.onNodeWithText("首次创建").assertDoesNotExist()
            assertFalse(store.networkUiReady())
        } finally {
            controller.pause().stop().destroy()
        }
        assertArrayEquals(damagedBytes, database.readBytes())
    }
}
