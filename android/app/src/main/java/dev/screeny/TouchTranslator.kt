package dev.screeny

import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.hypot

/**
 * One finger clicks and drags, two fingers scroll, and a two-finger tap right-clicks.
 *
 * The press is held back briefly so that a second finger landing right after the
 * first starts a scroll instead of clicking whatever is under the first finger.
 */
class TouchTranslator(
    private val view: View,
    private val send: (action: Int, a: Float, b: Float) -> Unit,
) {
    private enum class Mode { IDLE, PENDING, DRAGGING, TWO_FINGERS, IGNORING }

    private val handler = Handler(Looper.getMainLooper())
    private val slop = ViewConfiguration.get(view.context).scaledTouchSlop.toFloat()
    private val commitPress = Runnable { press() }

    private var mode = Mode.IDLE
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var travelled = 0f
    private var twoFingerStart = 0L

    fun attach() {
        view.setOnTouchListener { _, event ->
            onTouch(event)
            true
        }
    }

    private fun onTouch(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = Mode.PENDING
                downX = event.x
                downY = event.y
                handler.postDelayed(commitPress, PRESS_DELAY_MILLIS)
            }
            MotionEvent.ACTION_POINTER_DOWN -> if (mode == Mode.PENDING) startTwoFingers(event)
            MotionEvent.ACTION_MOVE -> onMove(event)
            MotionEvent.ACTION_POINTER_UP -> if (mode == Mode.TWO_FINGERS) finishTwoFingers(event)
            MotionEvent.ACTION_UP -> {
                handler.removeCallbacks(commitPress)
                if (mode == Mode.PENDING) press()
                if (mode == Mode.DRAGGING) sendPoint(UP, event.x, event.y)
                mode = Mode.IDLE
            }
            MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(commitPress)
                if (mode == Mode.DRAGGING) sendPoint(UP, event.x, event.y)
                mode = Mode.IDLE
            }
        }
    }

    private fun press() {
        mode = Mode.DRAGGING
        sendPoint(DOWN, downX, downY)
    }

    private fun onMove(event: MotionEvent) {
        when (mode) {
            Mode.PENDING -> {
                if (hypot(event.x - downX, event.y - downY) > slop) {
                    handler.removeCallbacks(commitPress)
                    press()
                    sendPoint(DRAG, event.x, event.y)
                }
            }
            Mode.DRAGGING -> sendPoint(DRAG, event.x, event.y)
            Mode.TWO_FINGERS -> {
                val x = centroidX(event)
                val y = centroidY(event)
                val dx = x - lastX
                val dy = y - lastY
                lastX = x
                lastY = y
                travelled += hypot(dx, dy)
                send(SCROLL, dx / view.width, dy / view.height)
            }
            else -> Unit
        }
    }

    private fun startTwoFingers(event: MotionEvent) {
        handler.removeCallbacks(commitPress)
        mode = Mode.TWO_FINGERS
        lastX = centroidX(event)
        lastY = centroidY(event)
        travelled = 0f
        twoFingerStart = event.eventTime
        sendPoint(HOVER, lastX, lastY)
    }

    private fun finishTwoFingers(event: MotionEvent) {
        if (travelled <= slop && event.eventTime - twoFingerStart < TAP_MILLIS) {
            sendPoint(RIGHT_CLICK, lastX, lastY)
        }
        mode = Mode.IGNORING
    }

    private fun sendPoint(action: Int, x: Float, y: Float) = send(action, x / view.width, y / view.height)

    private fun centroidX(event: MotionEvent) = (event.getX(0) + event.getX(1)) / 2

    private fun centroidY(event: MotionEvent) = (event.getY(0) + event.getY(1)) / 2

    private companion object {
        // Must match InputAction on the Mac.
        const val DOWN = 0
        const val DRAG = 1
        const val UP = 2
        const val SCROLL = 3
        const val RIGHT_CLICK = 4
        const val HOVER = 5

        const val PRESS_DELAY_MILLIS = 120L
        const val TAP_MILLIS = 300L
    }
}
