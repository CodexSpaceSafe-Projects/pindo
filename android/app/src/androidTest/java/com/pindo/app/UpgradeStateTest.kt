package com.pindo.app

import android.app.Application
import androidx.core.content.pm.PackageInfoCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.time.LocalDate

/** CI invokes seed, installs a higher-version APK with -r, then invokes verify. */
@RunWith(AndroidJUnit4::class)
class UpgradeStateTest {
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
    private val markers get() = app.getSharedPreferences("upgrade-verification", Application.MODE_PRIVATE)
    private fun version() = PackageInfoCompat.getLongVersionCode(app.packageManager.getPackageInfo(app.packageName, 0))

    @Test fun seed() {
        val store = AppStore(app)
        check(store.addGroup("升级保留分组", "#447766"))
        val group = store.state.value.groups.single()
        check(store.addTask("升级后保留事项", "# 原有备注\n\n- [ ] 继续完成", LocalDate.of(2026, 11, 16), group.id, null))
        check(store.setTheme("dark"))
        check(store.setDefaultGroup(group.id))
        DeviceNamePreferences(app).save("升级保留手机")
        markers.edit().putString("taskID", store.state.value.tasks.single().id).putString("groupID", group.id)
            .putLong("version", version()).commit().also { assertTrue(it) }
        // A real device-bound Android Keystore entry, not a fake JVM journal.
        V3SecretStorage(app).writeJournal(JSONObject().put("version", 3).put("enabled", false)
            .put("archived", JSONObject()).put("upgradeCheck", "retained-device-secret"))
        store.stopForeground()
    }

    @Test fun verify() {
        assertTrue("This must be a higher-version install, not a reinstall of the seed APK", version() > markers.getLong("version", Long.MAX_VALUE))
        assertEquals("Keystore credentials must remain decryptable", "retained-device-secret",
            V3SecretStorage(app).readJournal()?.getString("upgradeCheck"))
        val store = AppStore(app)
        val state = store.state.value
        assertFalse(state.readOnly)
        assertEquals("dark", state.preferences.theme)
        assertEquals("升级保留手机", DeviceNamePreferences(app).name)
        assertEquals(markers.getString("groupID", null), state.preferences.defaultGroupID)
        val task = state.tasks.single()
        assertEquals(markers.getString("taskID", null), task.id)
        assertEquals("升级后保留事项", task.title)
        assertEquals("# 原有备注\n\n- [ ] 继续完成", task.note)
        assertEquals(LocalDate.of(2026, 11, 16), task.day)
        assertEquals(state.groups.single().id, task.groupID)
        store.stopForeground()
    }
}
