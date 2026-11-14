package com.pindo.app.sync

import java.util.UUID

/** P0 only. Never reinterpret a v2 encrypted checkpoint as a v3 batch. */
object SyncV3 {
    const val MAX_COUNTER = 9_007_199_254_740_991L
    const val MAX_BATCH_BYTES = 128 * 1024
    const val MAX_OPERATIONS = 50
    const val MAX_CHUNK_BYTES = 64 * 1024
    fun validateCounter(value: Long) { require(value in 0..MAX_COUNTER) }
    fun validateID(value: String) { require(UUID.fromString(value).toString() == value) }
}

data class SyncV3Identity(val serviceID: String, val vaultID: String, val provider: String = "cloudflare-v3") {
    init { require(provider == "cloudflare-v3"); SyncV3.validateID(serviceID); SyncV3.validateID(vaultID) }
}

data class SyncV3EnvelopeContext(val identity: SyncV3Identity, val epoch: String, val kind: String,
    val objectID: String, val artifactIDs: List<String> = emptyList()) {
    fun associatedData(): ByteArray {
        listOf(identity.serviceID, identity.vaultID, epoch, objectID).forEach(SyncV3::validateID)
        require(kind in listOf("batch", "checkpoint", "chunk"))
        require(artifactIDs.size <= 50 && artifactIDs == artifactIDs.sorted().distinct() && artifactIDs.all { it.matches(Regex("[0-9a-f]{64}")) })
        return listOf("PindoSync/v3", identity.serviceID, identity.vaultID, epoch, kind, objectID, artifactIDs.joinToString(",")).joinToString("\n").toByteArray(Charsets.UTF_8)
    }
}

enum class SyncV3Error(val wire: String) {
    AUTHENTICATION_REQUIRED("authentication_required"), UNSUPPORTED_VERSION("unsupported_version"),
    EPOCH_MISMATCH("epoch_mismatch"), BATCH_CONFLICT("batch_conflict"), CHECKPOINT_REQUIRED("checkpoint_required"),
    CORRUPT_DATA("corrupt_data"), QUOTA_UNAVAILABLE("quota_unavailable"), STORAGE_UNAVAILABLE("storage_unavailable"),
    MAINTENANCE("maintenance"), INVALID_REQUEST("invalid_request"), CURSOR_MISMATCH("cursor_mismatch"),
    NOT_FOUND("not_found"), UNSUPPORTED_FEATURE("unsupported_feature")
}

data class SyncV3NoteDot(val actorID: String, val counter: Long) {
    init { SyncV3.validateID(actorID); SyncV3.validateCounter(counter); require(counter > 0) }
}

/** A note's observed dots never come from the global title/field clock. */
class SyncV3NoteRegister {
    private val writes = mutableMapOf<SyncV3NoteDot, String>()
    private val contexts = mutableMapOf<SyncV3NoteDot, Set<SyncV3NoteDot>>()
    private val removed = mutableSetOf<SyncV3NoteDot>()
    val visible: Map<SyncV3NoteDot, String> get() = writes.filterKeys { it !in removed }
    fun apply(dot: SyncV3NoteDot, value: String, observed: Set<SyncV3NoteDot>) {
        require(dot !in observed && value.toByteArray(Charsets.UTF_8).size <= SyncV3.MAX_CHUNK_BYTES)
        require(writes[dot] == null || (writes[dot] == value && contexts[dot] == observed)) { SyncV3Error.CORRUPT_DATA.wire }
        writes[dot] = value; contexts[dot] = observed.toSet(); removed.addAll(observed)
    }
    fun merge(other: SyncV3NoteRegister) {
        require(other.writes.all { (dot, value) -> writes[dot] == null || (writes[dot] == value && contexts[dot] == other.contexts[dot]) }) { SyncV3Error.CORRUPT_DATA.wire }
        writes.putAll(other.writes); contexts.putAll(other.contexts); removed.addAll(other.removed)
    }
}
