package com.pindo.app.sync

import java.util.UUID

/** The single supported encrypted sync protocol. */
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
        require(artifactIDs.size <= 512 && artifactIDs == artifactIDs.sorted().distinct() && artifactIDs.all { it.matches(Regex("[0-9a-f]{64}")) })
        return listOf("PindoSync/v3", identity.serviceID, identity.vaultID, epoch, kind, objectID, artifactIDs.joinToString(",")).joinToString("\n").toByteArray(Charsets.UTF_8)
    }
}

enum class SyncV3Error(val wire: String) {
    AUTHENTICATION_REQUIRED("authentication_required"), UNSUPPORTED_VERSION("unsupported_version"),
    EPOCH_MISMATCH("epoch_mismatch"), BATCH_CONFLICT("batch_conflict"), CHECKPOINT_REQUIRED("checkpoint_required"),
    CORRUPT_DATA("corrupt_data"), QUOTA_UNAVAILABLE("quota_unavailable"), STORAGE_UNAVAILABLE("storage_unavailable"),
    MAINTENANCE("maintenance"), INVALID_REQUEST("invalid_request"), CURSOR_MISMATCH("cursor_mismatch"),
    NOT_FOUND("not_found"), UNSUPPORTED_FEATURE("unsupported_feature"),
    BOOTSTRAP_CLOSED("bootstrap_closed"), PAIRING_INVALID("pairing_invalid"), CHECKPOINT_CONFLICT("checkpoint_conflict"), ARTIFACT_MISSING("artifact_missing"), LEASE_EXPIRED("lease_expired")
}
