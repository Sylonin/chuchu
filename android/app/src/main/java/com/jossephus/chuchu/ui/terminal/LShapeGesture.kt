package com.jossephus.chuchu.ui.terminal

import androidx.compose.ui.geometry.Offset
import kotlin.math.abs

/** An L-shaped one-finger drag: a horizontal leg first, then an upward leg. */
enum class LShapeGesture {
    LeftUp,
    RightUp,
}

/**
 * Recognises a horizontal drag followed by an upward drag, for one touch.
 *
 * The horizontal leg must come first and be mostly flat, otherwise normal
 * vertical scrolling would be mistaken for a gesture. While [isCommitted] is
 * true the caller must not scroll, so the upward leg does not move the
 * viewport. Positions are raw pointer pixels; [thresholdPx] is the length of
 * each leg.
 */
class LShapeGestureDetector(private val thresholdPx: Float) {
    private enum class Phase { Undecided, Horizontal, Fired, Rejected }

    private var phase = Phase.Undecided
    private var origin = Offset.Zero
    private var direction = 0f
    private var extremeX = 0f
    private var commitY = 0f
    private var lowestY = 0f

    /** True once the horizontal leg is recognised and until the touch is rejected. */
    val isCommitted: Boolean
        get() = phase == Phase.Horizontal || phase == Phase.Fired

    fun start(position: Offset) {
        phase = Phase.Undecided
        origin = position
    }

    /** Returns the gesture exactly once, on the move that completes the upward leg. */
    fun onMove(position: Offset): LShapeGesture? {
        when (phase) {
            Phase.Undecided -> onUndecidedMove(position)
            Phase.Horizontal -> return onHorizontalMove(position)
            Phase.Fired, Phase.Rejected -> Unit
        }
        return null
    }

    private fun onUndecidedMove(position: Offset) {
        val dx = position.x - origin.x
        val dy = position.y - origin.y
        if (abs(dx) >= thresholdPx && abs(dy) <= abs(dx) * MAX_LEG_SLOPE) {
            phase = Phase.Horizontal
            direction = if (dx < 0f) -1f else 1f
            extremeX = position.x
            commitY = position.y
            lowestY = position.y
        } else if (abs(dy) >= thresholdPx) {
            phase = Phase.Rejected
        }
    }

    private fun onHorizontalMove(position: Offset): LShapeGesture? {
        if ((position.x - extremeX) * direction > 0f) extremeX = position.x
        if (position.y > lowestY) lowestY = position.y
        // Coming back toward the start or dragging down is a different gesture.
        if ((extremeX - position.x) * direction > thresholdPx || lowestY - commitY > thresholdPx) {
            phase = Phase.Rejected
            return null
        }
        if (lowestY - position.y < thresholdPx) return null
        phase = Phase.Fired
        return if (direction < 0f) LShapeGesture.LeftUp else LShapeGesture.RightUp
    }

    private companion object {
        /** Max vertical drift, relative to the horizontal leg, that still counts as flat. */
        const val MAX_LEG_SLOPE = 0.5f
    }
}
