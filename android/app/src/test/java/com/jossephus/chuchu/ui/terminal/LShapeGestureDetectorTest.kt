package com.jossephus.chuchu.ui.terminal

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LShapeGestureDetectorTest {
    private val threshold = 100f

    private fun detector(): LShapeGestureDetector =
        LShapeGestureDetector(threshold).also { it.start(Offset(500f, 500f)) }

    // Offset is a value class and cannot be a vararg element type.
    private fun LShapeGestureDetector.feed(vararg points: Pair<Float, Float>): LShapeGesture? {
        var result: LShapeGesture? = null
        for ((x, y) in points) onMove(Offset(x, y))?.let { result = it }
        return result
    }

    @Test
    fun leftThenUpFires() {
        val d = detector()
        assertEquals(
            LShapeGesture.LeftUp,
            d.feed(450f to 500f, 390f to 495f, 385f to 450f, 385f to 380f),
        )
    }

    @Test
    fun rightThenUpFires() {
        val d = detector()
        assertEquals(
            LShapeGesture.RightUp,
            d.feed(560f to 505f, 620f to 500f, 620f to 440f, 625f to 390f),
        )
    }

    @Test
    fun firesOnlyOnce() {
        val d = detector()
        d.feed(380f to 500f, 380f to 390f)
        assertNull(d.onMove(Offset(380f, 300f)))
    }

    @Test
    fun upwardDragFirstIsPlainScroll() {
        val d = detector()
        assertNull(d.feed(500f to 420f, 500f to 380f, 380f to 380f, 380f to 250f))
        assertFalse(d.isCommitted)
    }

    @Test
    fun diagonalDragDoesNotFire() {
        val d = detector()
        assertNull(d.feed(440f to 440f, 380f to 380f, 320f to 320f, 260f to 260f))
        assertFalse(d.isCommitted)
    }

    @Test
    fun horizontalLegAloneDoesNotFireButSuppressesScroll() {
        val d = detector()
        assertNull(d.feed(420f to 500f, 300f to 500f))
        assertTrue(d.isCommitted)
    }

    @Test
    fun leftThenDownRejectsAndReleasesScroll() {
        val d = detector()
        assertNull(d.feed(380f to 500f, 380f to 560f, 380f to 640f, 380f to 300f))
        assertFalse(d.isCommitted)
    }

    @Test
    fun returningToStartRejects() {
        val d = detector()
        assertNull(d.feed(380f to 500f, 500f to 500f, 500f to 380f))
        assertFalse(d.isCommitted)
    }

    @Test
    fun shortUpwardLegDoesNotFire() {
        val d = detector()
        assertNull(d.feed(380f to 500f, 380f to 430f))
    }
}
