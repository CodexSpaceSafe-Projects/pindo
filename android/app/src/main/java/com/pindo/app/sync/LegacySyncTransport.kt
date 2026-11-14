package com.pindo.app.sync

// Metadata for local v1/v2 archive recovery and deterministic legacy tests only.
data class SyncRemoteHead(val key: String, val etag: String)
class SyncRemoteChangedException : IllegalStateException("同步对象在读取时发生变化。")
