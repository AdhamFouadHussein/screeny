package dev.screeny

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/** Connects to the Mac (through `adb reverse`), decodes its video and sends touch input back. */
class StreamClient(
    private val surface: Surface,
    displayWidth: Int,
    displayHeight: Int,
    private val onConnected: (Boolean) -> Unit,
) {
    private val size = fitToDecoder(displayWidth, displayHeight)
    private val inputExecutor = Executors.newSingleThreadExecutor()

    @Volatile private var running = false
    @Volatile private var socket: Socket? = null
    @Volatile private var output: DataOutputStream? = null
    private var worker: Thread? = null

    fun start() {
        running = true
        worker = thread(name = "screeny-stream") {
            while (running) {
                try {
                    runSession()
                } catch (_: IOException) {
                } catch (_: IllegalStateException) {
                    // MediaCodec reports a broken decoder this way; reconnect with a new one.
                }
                onConnected(false)
                if (running) Thread.sleep(RETRY_MILLIS)
            }
        }
    }

    /** Blocks until the decoder is released, so the surface is safe to destroy afterwards. */
    fun stop() {
        running = false
        try {
            socket?.close()
        } catch (_: IOException) {
        }
        worker?.join()
        inputExecutor.shutdown()
    }

    fun sendInput(action: Int, a: Float, b: Float) {
        if (inputExecutor.isShutdown) return
        inputExecutor.execute {
            try {
                output?.run {
                    writeByte(action)
                    writeFloat(a)
                    writeFloat(b)
                    flush()
                }
            } catch (_: IOException) {
            }
        }
    }

    private fun runSession() {
        Socket().use { sock ->
            socket = sock
            sock.tcpNoDelay = true
            sock.connect(InetSocketAddress(HOST, PORT), CONNECT_TIMEOUT_MILLIS)
            val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream()))
            out.writeBytes("SCRN")
            out.writeInt(PROTOCOL_VERSION)
            out.writeInt(size.first)
            out.writeInt(size.second)
            out.flush()
            output = out
            try {
                // With no Mac listening, adb accepts and then closes, so this read also
                // keeps the decoder from being created on every retry.
                val input = DataInputStream(BufferedInputStream(sock.getInputStream(), STREAM_BUFFER))
                val first = Packet.read(input)
                decode(input, first)
            } finally {
                output = null
            }
        }
    }

    private fun decode(input: DataInputStream, first: Packet) {
        val format = MediaFormat.createVideoFormat(MIME, size.first, size.second).apply {
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }
        val codec = MediaCodec.createDecoderByType(MIME)
        try {
            codec.configure(format, surface, null, 0)
            codec.start()
            val renderer = thread(name = "screeny-render") { render(codec) }
            try {
                onConnected(true)
                queue(codec, first)
                while (running) {
                    queue(codec, Packet.read(input))
                }
            } finally {
                renderer.interrupt()
                renderer.join()
                codec.stop()
            }
        } finally {
            codec.release()
        }
    }

    private fun queue(codec: MediaCodec, packet: Packet) {
        var index: Int
        do {
            if (!running) return
            index = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_MICROS)
        } while (index < 0)

        val buffer = codec.getInputBuffer(index) ?: throw IOException("no input buffer")
        buffer.clear()
        if (packet.payload.size > buffer.remaining()) throw IOException("packet larger than decoder buffer")
        buffer.put(packet.payload)
        val flags = if (packet.type == Packet.TYPE_CONFIG) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0
        codec.queueInputBuffer(index, 0, packet.payload.size, packet.ptsMicros, flags)
    }

    private fun render(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (!Thread.currentThread().isInterrupted) {
                val index = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_MICROS)
                if (index >= 0) codec.releaseOutputBuffer(index, true)
            }
        } catch (_: IllegalStateException) {
            // The decoder failed; the feeding thread sees the same error and reconnects.
        }
    }

    private class Packet(val type: Int, val ptsMicros: Long, val payload: ByteArray) {
        companion object {
            const val TYPE_CONFIG = 0
            private const val MAX_LENGTH = 16 * 1024 * 1024

            fun read(input: DataInputStream): Packet {
                val type = input.readUnsignedByte()
                val pts = input.readLong()
                val length = input.readInt()
                if (length !in 0..MAX_LENGTH) throw IOException("bad packet length $length")
                return Packet(type, pts, ByteArray(length).also(input::readFully))
            }
        }
    }

    private companion object {
        const val HOST = "127.0.0.1"
        const val PORT = 7878
        const val PROTOCOL_VERSION = 1
        const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        const val CONNECT_TIMEOUT_MILLIS = 2000
        const val RETRY_MILLIS = 1000L
        const val STREAM_BUFFER = 1 shl 20
        const val DEQUEUE_TIMEOUT_MICROS = 20_000L
        const val TARGET_FPS = 60.0

        /** Steps down from native resolution if this tablet's decoder can't handle it. */
        fun fitToDecoder(displayWidth: Int, displayHeight: Int): Pair<Int, Int> {
            val decoder = MediaCodec.createDecoderByType(MIME)
            val capabilities = try {
                decoder.codecInfo.getCapabilitiesForType(MIME).videoCapabilities
            } finally {
                decoder.release()
            }
            var width = displayWidth and -2
            var height = displayHeight and -2
            while (!capabilities.areSizeAndRateSupported(width, height, TARGET_FPS) && width > 640) {
                width = (width * 3 / 4) and -2
                height = (height * 3 / 4) and -2
            }
            return width to height
        }
    }
}
