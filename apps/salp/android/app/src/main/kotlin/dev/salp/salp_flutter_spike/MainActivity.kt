package dev.salp.salp

import android.app.Activity
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.os.Build
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var lockChannel: MethodChannel? = null
    private var systemLocked = false
    private var lockReceiverRegistered = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    systemLocked = true
                    lockChannel?.invokeMethod("lock", null)
                }
                Intent.ACTION_USER_PRESENT -> restoreSystemSession()
            }
        }
    }
    private fun restoreSystemSession() {
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (systemLocked && !keyguard.isKeyguardLocked) {
            systemLocked = false
            lockChannel?.invokeMethod("unlock", null)
        }
    }
    override fun onResume() {
        super.onResume()
        restoreSystemSession()
    }

    private val worker = Executors.newSingleThreadExecutor()
    private data class Write(val uri: Uri, val stream: OutputStream, val tree: Uri, val name: String, val temporaryName: String)
    private val journal by lazy { getSharedPreferences("salp_document_writes", MODE_PRIVATE) }
    private var recovered = 0
    private var uncertain = 0

    private fun names(tree: Uri): Set<String> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val result = mutableSetOf<String>()
        contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) result.add(cursor.getString(0))
        } ?: throw IllegalStateException("list")
        return result
    }

    private fun record(id: String, tree: Uri, temporary: String, name: String, committing: Boolean = false) {
        val value = JSONObject().put("tree", tree.toString()).put("temporary", temporary).put("name", name).put("committing", committing)
        check(journal.edit().putString(id, value.toString()).commit())
    }

    private fun forget(id: String) { check(journal.edit().remove(id).commit()) }

    private fun recover() {
        for ((id, raw) in journal.all) {
            try {
                val entry = JSONObject(raw as String)
                val tree = Uri.parse(entry.getString("tree"))
                val temporary = entry.getString("temporary")
                require(temporary.startsWith(".salp-") && temporary.endsWith(".part"))
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val found = mutableListOf<Uri>()
                contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) if (cursor.getString(1) == temporary) {
                        found.add(DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)))
                    }
                } ?: throw IllegalStateException("list")
                // Never delete the final name: a crash during rename has an
                // unknown commit result and the final document may be complete.
                for (uri in found) check(DocumentsContract.deleteDocument(contentResolver, uri))
                if (entry.optBoolean("committing")) uncertain++ else recovered++
                forget(id)
            } catch (_: Exception) { /* Permission/provider failure: retain journal for retry. */ }
        }
    }
    private val writes = mutableMapOf<String, Write>()
    private var picker: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        lockChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.salp/session-lock")
        if (!lockReceiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
            }
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else registerReceiver(screenReceiver, filter)
            lockReceiverRegistered = true
        }
        worker.execute { recover() }
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.salp/documents").setMethodCallHandler { call, result ->
            if (call.method == "chooseDirectory") {
                if (picker != null) { result.error("busy", "文件选择器已打开", null); return@setMethodCallHandler }
                picker = result
                try {
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }, 8201)
                } catch (_: Exception) { picker = null; result.error("unavailable", "无法打开目录选择器", null) }
                return@setMethodCallHandler
            }
            if (call.method == "recovery") {
                worker.execute {
                    val status = mapOf("recovered" to recovered, "uncertain" to uncertain, "pending" to journal.all.size)
                    runOnUiThread { result.success(status) }
                }
                return@setMethodCallHandler
            }
            if (call.method !in setOf("create", "write", "finish", "abort")) {
                result.notImplemented(); return@setMethodCallHandler
            }
            worker.execute {
                try {
                    var value: String? = null
                    when (call.method) {
                        "create" -> {
                            if (writes.size >= 16) throw IllegalStateException("capacity")
                            val tree = Uri.parse(requireNotNull(call.argument<String>("directory")))
                            require(tree.scheme == "content")
                            val requested = requireNotNull(call.argument<String>("name"))
                            require(requested.isNotBlank() && requested !in setOf(".", "..") && !requested.contains('/') && !requested.contains('\u0000'))
                            val parentId = DocumentsContract.getTreeDocumentId(tree)
                            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
                            val names = names(tree)
                            val name = if (requested in names) {
                                if (call.argument<Boolean>("keepBoth") != true) {
                                    runOnUiThread { result.error("conflict", "目标已存在", null) }; return@execute
                                }
                                "$requested.copy-${UUID.randomUUID()}"
                            } else requested
                            val id = UUID.randomUUID().toString()
                            val temporary = ".salp-$id.part"
                            // Persist the unique intended name before creation. Recovery
                            // can find it even if the process dies before we obtain its URI.
                            record(id, tree, temporary, name)
                            val uri = DocumentsContract.createDocument(contentResolver, parent, "application/octet-stream", temporary)
                                ?: throw IllegalStateException("create")
                            val output = try { contentResolver.openOutputStream(uri, "w") ?: throw IllegalStateException("open") }
                            catch (e: Exception) {
                                if (DocumentsContract.deleteDocument(contentResolver, uri)) forget(id)
                                throw e
                            }
                            writes[id] = Write(uri, output, tree, name, temporary); value = id
                        }
                        "write" -> {
                            val output = writes[requireNotNull(call.argument<String>("id"))] ?: throw IllegalStateException("closed")
                            val bytes = requireNotNull(call.argument<ByteArray>("bytes")); require(bytes.size <= 65536)
                            output.stream.write(bytes)
                        }
                        "finish" -> {
                            val id = requireNotNull(call.argument<String>("id"))
                            val output = writes[id] ?: throw IllegalStateException("closed")
                            output.stream.flush(); output.stream.close()
                            if (output.name in names(output.tree)) {
                                runOnUiThread { result.error("conflict", "目标已存在，未覆盖", null) }; return@execute
                            }
                            record(id, output.tree, output.temporaryName, output.name, committing = true)
                            // From this point a provider failure may mean rename
                            // committed. Abort must never delete the final URI.
                            writes.remove(id)
                            val renamed = DocumentsContract.renameDocument(contentResolver, output.uri, output.name)
                                ?: throw IllegalStateException("rename")
                            // The rename may change the URI. After it succeeds the
                            // final document is never an abort/cleanup candidate.
                            forget(id)
                            value = renamed.toString()
                        }
                        "abort" -> {
                            val id = requireNotNull(call.argument<String>("id"))
                            writes.remove(id)?.let { output ->
                                try { output.stream.close() } finally {
                                    if (DocumentsContract.deleteDocument(contentResolver, output.uri)) forget(id)
                                }
                            }
                        }
                    }
                    runOnUiThread { result.success(value) }
                } catch (_: Exception) { runOnUiThread { result.error("document_io", "文件操作失败，请检查授权或可用空间", null) } }
            }
        }
    }
    @Deprecated("Activity result bridge for Flutter")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 8201) return
        val result = picker ?: return; picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            result.success(uri.toString())
        } catch (_: Exception) { result.error("permission", "无法保留目录授权", null) }
    }
    override fun onDestroy() {
        if (lockReceiverRegistered) { unregisterReceiver(screenReceiver); lockReceiverRegistered = false }
        lockChannel = null
        picker?.error("closed", "窗口已关闭", null); picker = null
        worker.execute {
            writes.forEach { (id, output) ->
                try {
                    output.stream.close()
                    if (DocumentsContract.deleteDocument(contentResolver, output.uri)) forget(id)
                } catch (_: Exception) { }
            }
            writes.clear()
        }
        worker.shutdown()
        super.onDestroy()
    }
}
