package com.pindo.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.pindo.app.sync.toMap
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.time.LocalDate

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class AppStoreRulesTest {
    private lateinit var app: Application
    private lateinit var store: AppStore
    private val day = LocalDate.of(2026, 11, 17)

    @Before fun prepare() {
        app = ApplicationProvider.getApplicationContext()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.noBackupFilesDir.listFiles()?.forEach { it.deleteRecursively() }
        store = AppStore(app)
    }

    @After fun stop() { store.stopForeground() }

    private fun displayedIDs(source: AppStore) = TodoQueries.matching(source.state.value.tasks,
        TaskQuery(scope = TaskScope.ALL, phase = PhaseFilter.ALL)).map { it.id }

    private fun persistedIDs(): List<String> {
        val restarted = AppStore(app)
        return displayedIDs(restarted).also { restarted.stopForeground() }
    }

    @Test fun movingEqualOrderTasksUsesTheirDisplayedCreationOrderAndPersistsBothDirections() {
        // Two devices can independently create order 0. Their UUID ordering is
        // unrelated to the creation time used to display the merged siblings.
        val earlier = TodoRules.newTask("较早的离线事项", "保留备注 A", day, null, null, 0)
            .put("id", "22222222-2222-4222-8222-222222222222").put("createdAt", 1.0).put("updatedAt", 1.0)
        val later = TodoRules.newTask("较晚的离线事项", "保留备注 B", day, null, null, 0)
            .put("id", "11111111-1111-4111-8111-111111111111").put("createdAt", 2.0).put("updatedAt", 2.0)
        val original = emptyDocument().put("tasks", JSONArray().put(earlier).put(later)).toString()
        val first = earlier.getString("id")
        val second = later.getString("id")

        for ((id, offset) in listOf(first to 1, second to -1)) {
            assertTrue(store.importData(original))
            assertEquals(listOf(first, second), displayedIDs(store))
            assertTrue(store.move(id, offset))
            assertEquals(listOf(second, first), displayedIDs(store))
            assertEquals(listOf(second, first), persistedIDs())
            assertEquals(setOf("保留备注 A", "保留备注 B"), store.state.value.tasks.map { it.note }.toSet())
        }
    }

    @Test fun unrelatedAddAndSingleOrBatchDeletePreserveReopenedFamilyInSQLite() {
        val grandparent = TodoRules.newTask("祖父项", "", day, null, null, 0)
        val parent = TodoRules.newTask("父项", "", day, null, grandparent.getString("id"), 1)
        val child = TodoRules.newTask("子项", "", day, null, parent.getString("id"), 2)
        val other = TodoRules.newTask("待批量删除", "", day, null, null, 3)
        val completed = TodoRules.setPhase(JSONArray().put(grandparent).put(parent).put(child).put(other),
            grandparent.getString("id"), "completed")
        val reopened = TodoRules.setPhase(completed, parent.getString("id"), "inProgress")
        val expected = reopened.objects().take(3).associate { it.getString("id") to it.toMap() }
        assertTrue(store.importData(emptyDocument().put("tasks", reopened).toString()))

        fun assertPreserved() {
            val persisted = DocumentStorage(app).read().getJSONArray("tasks").objects()
                .filter { it.getString("id") in expected }.associate { it.getString("id") to it.toMap() }
            assertEquals(expected, persisted)
            assertEquals("inProgress", store.state.value.tasks.first { it.id == parent.getString("id") }.phase)
        }

        assertTrue(store.addTask("新根项", "", day, null, null))
        assertPreserved()
        val addedID = store.state.value.tasks.single { it.title == "新根项" }.id
        assertTrue(store.deleteTask(addedID))
        assertPreserved()
        assertTrue(store.batchDelete(setOf(other.getString("id"))))
        assertPreserved()
        assertEquals(expected.keys, persistedIDs().toSet())
    }
}
