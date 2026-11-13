package com.yamax.veer.core_profile.internal.parser

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject

// ---------------------------------------------------------------------------
// Safe accessors for SnakeYAML's Map<String, Any> output
// ---------------------------------------------------------------------------

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.str(key: String): String? = this[key]?.toString()

internal fun Map<String, Any?>.int(key: String): Int? = when (val v = this[key]) {
    is Int    -> v
    is Long   -> v.toInt()
    is String -> v.toIntOrNull()
    else      -> null
}

internal fun Map<String, Any?>.bool(key: String): Boolean? = when (val v = this[key]) {
    is Boolean -> v
    is String  -> when (v.lowercase()) { "true", "yes", "on" -> true; "false", "no", "off" -> false; else -> null }
    else       -> null
}

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.map(key: String): Map<String, Any?>? =
    this[key] as? Map<String, Any?>

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.list(key: String): List<Any?>? =
    this[key] as? List<Any?>

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.strList(key: String): List<String>? =
    (this[key] as? List<*>)?.filterIsInstance<String>()?.takeIf { it.isNotEmpty() }

// ---------------------------------------------------------------------------
// SnakeYAML Any → JsonElement conversion (for storing extras)
// ---------------------------------------------------------------------------

internal fun Any?.toJsonElement(): JsonElement = when (this) {
    null       -> JsonNull
    is Boolean -> JsonPrimitive(this)
    is Int     -> JsonPrimitive(this)
    is Long    -> JsonPrimitive(this)
    is Double  -> JsonPrimitive(this)
    is Float   -> JsonPrimitive(this.toDouble())
    is String  -> JsonPrimitive(this)
    is Map<*, *> -> buildJsonObject {
        forEach { (k, v) -> put(k.toString(), v.toJsonElement()) }
    }
    is Collection<*> -> buildJsonArray { forEach { add(it.toJsonElement()) } }
    else -> JsonPrimitive(toString())
}

// ---------------------------------------------------------------------------
// JsonElement → Any (for SnakeYAML dump round-trip in generator)
// ---------------------------------------------------------------------------

internal fun JsonElement.toSnakeYamlAny(): Any? = when (this) {
    is JsonNull      -> null
    is JsonPrimitive -> when {
        isString                      -> content
        content == "true"             -> true
        content == "false"            -> false
        content.toIntOrNull() != null -> content.toInt()
        content.toLongOrNull() != null -> content.toLong()
        content.toDoubleOrNull() != null -> content.toDouble()
        else                          -> content
    }
    is JsonObject -> entries.mapNotNull { (k, v) ->
        val any = v.toSnakeYamlAny()
        if (any != null) k to any else null
    }.toMap()
    is JsonArray  -> mapNotNull { it.toSnakeYamlAny() }
}
