package com.pindo.app

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Exercises rendered update controls without a network, APK or install permission. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AppUpdateScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun checkingStartsOnlyFromThePrimaryActionAndUnsupportedBuildsCannotStartIt() {
        var state by mutableStateOf(AppUpdateState())
        var checks = 0
        var backs = 0
        compose.setContent {
            PindoTheme("light") {
                AppUpdateContent(CURRENT_VERSION, state, onBack = { backs++ }, onStart = { checks++ },
                    onCancel = {}, onInstall = {})
            }
        }
        compose.onNodeWithTag("app-update-screen").assertIsDisplayed()
        compose.onNode(hasText(CURRENT_VERSION, substring = true)).assertExists()
        compose.runOnIdle { assertEquals(0, checks) }
        compose.onNodeWithText("检查并更新").assertIsDisplayed().performClick()
        compose.onNodeWithContentDescription("返回设置").performClick()
        compose.runOnIdle {
            assertEquals(1, checks)
            assertEquals(1, backs)
            state = AppUpdateState(stage = AppUpdateStage.UNSUPPORTED, message = "开发版本不能覆盖正式版本。")
        }
        compose.onNodeWithText("开发版本不能覆盖正式版本。").assertExists()
        compose.onNodeWithTag("update-primary").assertDoesNotExist()
        compose.runOnIdle { assertEquals(1, checks) }
    }

    @Test fun downloadReportsDeterminateProgressAndCancelDoesNotStartAnInstall() {
        var cancels = 0
        var installs = 0
        val state = AppUpdateState(stage = AppUpdateStage.DOWNLOADING, versionName = NEW_VERSION,
            downloadedBytes = 3L * MIB, totalBytes = 12L * MIB, message = "正在下载更新")
        compose.setContent {
            PindoTheme("light") {
                AppUpdateContent(CURRENT_VERSION, state, onBack = {}, onStart = {},
                    onCancel = { cancels++ }, onInstall = { installs++ })
            }
        }
        compose.onNodeWithTag("update-progress")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ProgressBarRangeInfo,
                ProgressBarRangeInfo(0.25f, 0f..1f)))
        compose.onNode(hasText(NEW_VERSION, substring = true)).assertExists()
        compose.onNodeWithTag("update-cancel").assertIsEnabled().assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertEquals(1, cancels)
            assertEquals(0, installs)
        }
    }

    @Test fun failedChecksAndCancelledPermissionCanBeRetriedWithoutConfusingDownloadAndInstall() {
        var state by mutableStateOf(AppUpdateState(stage = AppUpdateStage.ERROR, message = "网络暂不可用，请重试。"))
        var permissionMessage by mutableStateOf<String?>(null)
        var checks = 0
        var installs = 0
        compose.setContent {
            PindoTheme("light") {
                AppUpdateContent(CURRENT_VERSION, state, permissionMessage = permissionMessage,
                    onBack = {}, onStart = { checks++ }, onCancel = {}, onInstall = { installs++ })
            }
        }
        compose.onNodeWithText("网络暂不可用，请重试。").assertExists()
        compose.onNodeWithText("重试更新").performClick()
        compose.runOnIdle {
            assertEquals(1, checks)
            assertEquals(0, installs)
            state = AppUpdateState(stage = AppUpdateStage.READY, versionName = NEW_VERSION)
            permissionMessage = "请允许安装此来源的应用。"
        }
        compose.onNodeWithText("请允许安装此来源的应用。").assertExists()
        compose.onNodeWithText("安装更新").assertIsEnabled().performClick()
        compose.runOnIdle {
            assertEquals(1, installs)
            assertEquals(1, checks)
            state = AppUpdateState(stage = AppUpdateStage.UP_TO_DATE)
            permissionMessage = null
        }
        compose.onNodeWithText("重新检查").performClick()
        compose.runOnIdle {
            assertEquals(2, checks)
            assertEquals(1, installs)
        }
    }

    @Test @Config(qualifiers = "zh-rCN-w320dp-h640dp-xhdpi")
    fun narrowLargeTextKeepsTheMainActionTouchableAndBusyStagesCannotRestartWork() {
        var state by mutableStateOf(AppUpdateState())
        var checks = 0
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 1.6f)) {
                PindoTheme("light") {
                    AppUpdateContent(CURRENT_VERSION, state, onBack = {}, onStart = { checks++ },
                        onCancel = {}, onInstall = {})
                }
            }
        }
        compose.onNodeWithTag("update-primary").assertIsDisplayed()
            .assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp).performClick()
        for (stage in listOf(AppUpdateStage.CHECKING, AppUpdateStage.VERIFYING, AppUpdateStage.INSTALLING)) {
            compose.runOnIdle { state = AppUpdateState(stage = stage, versionName = NEW_VERSION) }
            compose.onNodeWithTag("update-primary").assertIsDisplayed().assertIsNotEnabled()
                .performTouchInput { click() }
            compose.runOnIdle { assertEquals("Busy controls must not start another check", 1, checks) }
        }
    }

    private companion object {
        const val CURRENT_VERSION = "0.6.0-build70.abcdef0"
        const val NEW_VERSION = "0.6.0-build71.1234567"
        const val MIB = 1024L * 1024L
    }
}
