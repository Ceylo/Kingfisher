// Plays an animated image in place of the static first frame `KFAnimatedImage` draws on
// Android. Lives in the Skip folder because the module is native Swift, which cannot
// reach `android.graphics` or Compose; Sources/SwiftUI/KFAnimatedImage.swift creates it
// by name through SkipBridge's `AnyDynamicObject`.
//
// `AnimatedImageDrawable` decodes its frames on the RenderThread, so no frame array is
// held anywhere: the memory cache keeps only the encoded bytes and the first frame.

package kingfisher

import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateDraw
import java.nio.ByteBuffer
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import skip.ui.ContentModifier
import skip.ui.View

/// Applied to the `Image(holder:)` that draws the first frame. One instance per
/// decoded image, so `data` crosses JNI once however often the view recomposes.
class KFAnimatedImageModifier(private val data: ByteArray) : ContentModifier {
    override fun modify(view: View): View =
        view.composeModifier { it.then(AnimatedImageElement(data)) }
}

private class AnimatedImageElement(val data: ByteArray) : ModifierNodeElement<AnimatedImageNode>() {
    override fun create() = AnimatedImageNode(data)

    override fun update(node: AnimatedImageNode) = node.update(data)

    // By identity: the same bytes keep the node, and the animation, across recompositions.
    override fun equals(other: Any?) = other is AnimatedImageElement && other.data === data

    override fun hashCode() = System.identityHashCode(data)
}

/// Draws the image's content (the static frame) until the drawable is decoded, then the
/// drawable instead, stretched to the node as iOS's `AnimatedImageView` is. A frame
/// change invalidates the draw only, never the composition.
private class AnimatedImageNode(private var data: ByteArray) : Modifier.Node(), DrawModifierNode {
    private var drawable: AnimatedImageDrawable? = null
    private var decoding: Job? = null

    // `Drawable` keeps its callback weakly, so the node holds it.
    private val callback = object : Drawable.Callback {
        override fun invalidateDrawable(who: Drawable) = invalidateDraw()

        override fun scheduleDrawable(who: Drawable, what: Runnable, `when`: Long) {
            mainHandler.postAtTime(what, `when`)
        }

        override fun unscheduleDrawable(who: Drawable, what: Runnable) {
            mainHandler.removeCallbacks(what)
        }
    }

    fun update(data: ByteArray) {
        if (data === this.data) return
        this.data = data
        if (isAttached) {
            stop()
            start()
        }
    }

    override fun onAttach() = start()

    override fun onDetach() = stop()

    private fun start() {
        val bytes = data
        decoding = coroutineScope.launch {
            // Not an `AnimatedImageDrawable` only for data Kingfisher could not walk: the
            // static frame stays.
            val decoded = withContext(Dispatchers.Default) {
                runCatching { ImageDecoder.decodeDrawable(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) }
                    .getOrNull() as? AnimatedImageDrawable
            } ?: return@launch
            decoded.callback = callback
            decoded.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
            decoded.start()
            drawable = decoded
            invalidateDraw()
        }
    }

    private fun stop() {
        decoding?.cancel()
        decoding = null
        drawable?.let {
            it.stop()
            it.callback = null
        }
        drawable = null
    }

    override fun ContentDrawScope.draw() {
        val drawable = drawable ?: return drawContent()
        drawable.setBounds(0, 0, size.width.roundToInt(), size.height.roundToInt())
        drawIntoCanvas { drawable.draw(it.nativeCanvas) }
    }

    companion object {
        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
