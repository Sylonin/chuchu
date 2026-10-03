# Terminal fling (inertial) scrolling

## Context
Terminal scrolling in chuchu tracks the finger 1:1, row by row, and stops dead on release. The user wants scrolling like a typical touchscreen app (Termius): a quick swipe keeps scrolling with momentum and decelerates, so a fast downward swipe scrolls far up into scrollback. End state: one-finger vertical drags still scroll as today. On release with enough vertical velocity, the terminal keeps scrolling along an Android-native spline decay. Touching the screen stops the fling.

All gesture code lives in `android/app/src/main/java/com/jossephus/chuchu/ui/terminal/TerminalCanvas.kt`, function `TerminalCanvas`, inside `baseModifier.pointerInput(Unit) { awaitEachGesture { … } }` (about lines 297-563). Scroll output already goes through `scrollDeltaChannel` (line 222). That channel coalesces deltas once per frame and calls `onScroll(delta, x, y)`, which reaches `TerminalSessionEngine.scroll` → `bridge.nativeScroll`. Ghostty turns those deltas into viewport scrolling, or into mouse wheel events when an app uses mouse tracking. Fling reuses this path unchanged. Sign convention, from the existing drag code at lines 532-543: `dragRemainder += dragY / cellHeight`, then `TerminalScrollDelta(-delta, …)`. A finger moving down (positive y) sends a negative delta, which scrolls up into history.

## Approach

### 1. Fling state holder and launcher (new private helpers at the bottom of TerminalCanvas.kt)
- Add a holder next to `DoubleTapState` (about line 1067), following the same pattern: plain fields, no Compose state, so writes do not trigger recomposition.
  ```kotlin
  /** Holds the running scroll fling so a new touch or session switch can stop it. */
  private class ScrollFlingState {
      var job: Job? = null
      /** Cancels any running fling; returns true if one was still moving. */
      fun stop(): Boolean {
          val wasActive = job?.isActive == true
          job?.cancel()
          job = null
          return wasActive
      }
  }
  ```
- Add a top-level private launcher. Nothing equivalent exists in the file. The selection auto-scroll at lines 366-376 sends fixed row bursts on a timer and is not a decay.
  ```kotlin
  private fun CoroutineScope.launchScrollFling(
      initialVelocityPxPerSec: Float,
      initialRemainderRows: Float,
      cellHeightPx: Float,
      decay: DecayAnimationSpec<Float>,
      x: Float,
      y: Float,
      send: (TerminalScrollDelta) -> Unit,
  ): Job = launch {
      var carryRows = initialRemainderRows
      var lastValue = 0f
      AnimationState(initialValue = 0f, initialVelocity = initialVelocityPxPerSec).animateDecay(decay) {
          carryRows += (value - lastValue) / cellHeightPx
          lastValue = value
          val whole = carryRows.toInt()
          if (whole != 0) {
              carryRows -= whole
              send(TerminalScrollDelta(-whole, x, y))
          }
      }
  }
  ```
  The `-whole` sign matches the drag path, so a downward fling scrolls up into history.
- Imports to add: `androidx.compose.animation.core.AnimationState`, `androidx.compose.animation.core.DecayAnimationSpec`, `androidx.compose.animation.core.animateDecay`, `androidx.compose.animation.rememberSplineBasedDecay`, `androidx.compose.runtime.rememberCoroutineScope`, `androidx.compose.ui.input.pointer.util.VelocityTracker`, `kotlinx.coroutines.CoroutineScope`, `kotlinx.coroutines.Job`, `kotlinx.coroutines.launch`. The animation artifacts come in transitively through `androidx.compose.foundation` (BOM 2024.09.00), so no Gradle change is needed. If the import does not resolve, add `implementation("androidx.compose.animation:animation")` (BOM-managed, no version) to `android/app/build.gradle.kts` next to the foundation line.

### 2. Composable-level wiring in `TerminalCanvas`
Place these next to the existing `doubleTapState` / ViewConfiguration values (about lines 87-93):
- `val flingState = remember { ScrollFlingState() }`
- `val flingScope = rememberCoroutineScope()`. Its frame clock drives `animateDecay`, and Compose cancels it when the canvas leaves composition.
- `val flingDecay = rememberSplineBasedDecay<Float>()`. This is Android's native scroller curve, the same one `LazyColumn` and `ScrollView` use.
- `val minFlingVelocityPx = remember(androidViewConfiguration) { androidViewConfiguration.scaledMinimumFlingVelocity.toFloat() }`
- `val maxFlingVelocityPx = remember(androidViewConfiguration) { androidViewConfiguration.scaledMaximumFlingVelocity.toFloat() }`
- Add `rememberUpdatedState` wrappers alongside the others (lines 195-216): `currentFlingDecay`, `currentMinFlingVelocityPx`, `currentMaxFlingVelocityPx`.
- Add `LaunchedEffect(terminalHandle) { flingState.stop() }`, so switching sessions or tabs does not keep scrolling the newly shown terminal.

### 3. Gesture loop changes (inside `awaitEachGesture`)
- Right after `val down = awaitFirstDown(requireUnconsumed = false)`: `val interruptedFling = flingState.stop()`.
- With the other per-gesture vars (lines 313-326): `val velocityTracker = VelocityTracker()` and `var lastScrollPos = Offset.Zero`. Then seed the tracker with `velocityTracker.addPosition(down.uptimeMillis, toSnapshotSpace(down.position, currentSnapshot.value))`.
- In the two-finger branch (`if (pressed.size >= 2)`, line 436): call `velocityTracker.resetTracking()`. A pinch never flings, because the release check below requires `!didPinch`.
- In the plain scroll path, after `val dragY = …` (line 513) and before the slop check: `velocityTracker.addPosition(change.uptimeMillis, changePos)` and `lastScrollPos = changePos`. The selection-drag and app-mouse-drag branches `continue` earlier and do not feed the tracker.
- In the release branch (`if (pressed.isEmpty())`, line 381), after the `if (releasedDragMode != DragMode.None) break` check:
  - If `didScroll && !didPinch`: compute `val v = velocityTracker.calculateVelocity()`. If `abs(v.y) >= currentMinFlingVelocityPx.value && abs(v.y) > abs(v.x)`, then set `flingState.job = flingScope.launchScrollFling(initialVelocityPxPerSec = v.y.coerceIn(-max, max), initialRemainderRows = dragRemainder, cellHeightPx = currentCellHeight.value, decay = currentFlingDecay.value, x = lastScrollPos.x, y = lastScrollPos.y, send = { scrollDeltaChannel.trySend(it) })`, where `max = currentMaxFlingVelocityPx.value`. Then `break`. A drag that ends slowly (below the minimum velocity) just stops, as today.
  - Change the tap condition `if (!didScroll && !didPinch && !didDragGesture)` to `if (!didScroll && !didPinch && !didDragGesture && !interruptedFling)`. A tap that stops a fling then only stops it. It does not send a primary click, clear the selection, toggle the keyboard via `onTap`, or count toward a double-tap. This is standard Android behavior.
- Leave long-press handling unchanged. A long press that starts by stopping a fling still starts a selection, as in Android text views.

## Critical files & anchors
- `android/app/src/main/java/com/jossephus/chuchu/ui/terminal/TerminalCanvas.kt`, `TerminalCanvas` gesture loop (lines 297-563): the only file with behavior changes.
- Same file, `scrollDeltaChannel` consumer (lines 222-238): reused as is. It coalesces fling deltas per frame, so no new rate limiting is needed.
- `android/app/src/main/java/com/jossephus/chuchu/service/terminal/TerminalSessionEngine.kt`, `scroll` (line 447): sink. Needs no change; listed so the implementer does not add a second scroll path.

## Verification
1. Compile, from the repo root: `devenv shell -- bash -c 'cd android && ANDROID_ABI_FILTERS=arm64-v8a gradle --console=plain compileDebugKotlin 2>&1 | grep -E "^e: |BUILD"'`. Expect `BUILD SUCCESSFUL`.
2. Unit tests: `devenv shell -- bash -c 'cd android && gradle --console=plain testDebugUnitTest 2>&1 | grep -E "FAILED|BUILD"'`. Expect `BUILD SUCCESSFUL` and no `FAILED`.
3. Build and copy the APK: `devenv shell -- just apk && cp android/app/build/outputs/apk/debug/app-debug.apk ~/MiscDocs/app-debug.apk`.
4. Manual checks on the phone (install `~/MiscDocs/app-debug.apk`, connect to any host):
   - Run `seq 1 5000`. A quick downward flick scrolls up hundreds of lines and decelerates smoothly. A quick upward flick scrolls back toward the bottom.
   - A slow drag still moves row by row and stops when lifted, with no drift.
   - During a fling, tapping once stops scrolling immediately. The keyboard does not toggle and no click is sent.
   - Pinch-zoom changes the font size and never flings.
   - Long-press selection still works, including edge auto-scroll while dragging a selection.
   - In `less` on a long file, a flick scrolls with momentum through wheel events.
   - Switching tabs during a fling stops it. The other tab's viewport does not move.

## Assumptions & contingencies
- Fling physics use Android's stock spline decay with the system minimum and maximum fling velocities, with no custom multiplier and no settings toggle. If the user finds it too weak or too strong, the follow-up is a velocity multiplier applied to `initialVelocityPxPerSec`. It is not part of this change.
