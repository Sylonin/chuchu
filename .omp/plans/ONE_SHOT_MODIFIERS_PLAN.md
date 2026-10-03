# One-shot accessory modifiers with long-press lock

## Context

Today, tapping Ctrl, Alt, Shift or Cmd in the terminal accessory bar keeps the modifier on until the user taps it again. Upstream added this on purpose in jossephus/chuchu PR #24 ("Makes accessory modifiers sticky until tapped again"). Upstream `main` (`c233110`) is the base of the `personal` branch, and no open upstream PR changes it.

New behaviour:
- **Tap:** the modifier applies to the next key only. Example: tap Ctrl, then `b`, sends Ctrl+B and releases Ctrl.
- **Tap again before a key:** cancels the modifier.
- **Long-press:** locks the modifier on, so it stays on across keys. Tapping or long-pressing a locked modifier releases it.

## Execution

Run the Approach steps through serial `task` subagents, one per change group. Start each agent only after the previous one has finished. Give each agent this plan file (`local://one-shot-modifiers-plan.md`) plus its group below. Agents must not run builds, tests or formatters. The orchestrator runs Verification once all three have finished.

1. **Agent `ModifierModel`:** Approach steps 1, 2 and 5. The model, dispatcher and unit tests change together because the tests reference the new API.
2. **Agent `ScreenConsume`:** Approach step 3 (`TerminalScreen.kt`). It depends on `consumeOneShot()` from agent 1.
3. **Agent `LongPressUi`:** Approach step 4 (`ChuButton.kt`, `KeyboardAccessoryBar.kt`). It depends on `LockModifier` and `isLocked()` from agent 1.

After all three agents finish, the orchestrator runs Verification steps 1 and 2. If either fails, the orchestrator fixes the failure directly rather than re-spawning an agent. Commit only when the user asks.

## Approach

### 1. Model: add a lock set and one-shot consumption to `ModifierState`

File: `android/app/src/main/java/com/jossephus/chuchu/ui/terminal/TerminalAccessory.kt`.

- Add the field `val locked: Set<TerminalModifier> = emptySet()` as the last constructor parameter of `ModifierState`.
  - Invariant: every member of `locked` also has its boolean (`ctrl`, `alt`, `shift`, `cmd`) set to `true`.
  - Keep the booleans as the "active" state, so that `terminalMods()`, `applyToText()`, `isEnabled()` and `hasActiveModifiers()` stay unchanged.
  - `modifierStateForCustomAction` in `TerminalCustomActions.kt` and the `ModifierState()` callers need no change, because `locked` defaults to `emptySet()`.
- Add two private helpers:
  - `activate(modifier: TerminalModifier): ModifierState` sets the matching boolean to `true`.
  - `deactivate(modifier: TerminalModifier): ModifierState` sets the matching boolean to `false` and removes the modifier from `locked`.
  - Do not name them `with`/`without`, because `with` would shadow the stdlib function.
- Replace the body of `toggle(modifier)` with `if (isEnabled(modifier)) deactivate(modifier) else activate(modifier)`.
  - This handles the tap case: it arms a one-shot modifier, or cancels an armed or locked one.
  - Keep the name `toggle`. Its only callers are the dispatcher and `AccessoryLogicTest`.
- Add `fun toggleLock(modifier: TerminalModifier): ModifierState`:
  - If the modifier is in `locked`, return `deactivate(modifier)`.
  - Otherwise return `activate(modifier).copy(locked = locked + modifier)`.
- Add `fun isLocked(modifier: TerminalModifier): Boolean = modifier in locked`.
- Add `fun consumeOneShot(): ModifierState`. It returns `ModifierState(ctrl = ctrl && TerminalModifier.Ctrl in locked, alt = …, shift = …, cmd = …, locked = locked)`, with the same pattern for each of the four modifiers.
- Add `data class LockModifier(val modifier: TerminalModifier) : AccessoryAction` to `AccessoryAction`, directly under `ToggleModifier`.
  - `LockModifier` is only sent from a long-press. It never appears in the catalog or in persisted layouts, so `TerminalAccessoryLayoutStore` is not touched.

### 2. Dispatcher: consume one-shot modifiers on key actions

Change `TerminalAccessoryDispatcher.dispatch` in the same file as follows:
- **`ToggleModifier`:** `modifierState.toggle(action.modifier)` (unchanged call).
- **`LockModifier` (new branch):** `AccessoryDispatchResult(modifierState = modifierState.toggleLock(action.modifier))`.
- **`SendSpecialKey`:** set `modifierState = modifierState.consumeOneShot()`. `specialKey` and `suppressImeInput = true` stay as they are.
- **`SendText`:** set `modifierState = modifierState.consumeOneShot()`. `text = modifierState.applyToText(action.text)` still uses the incoming state.
- **`Paste`:** leave `modifierState` unchanged, because `pasteClipboard()` consumes it in step 3. Consuming it here would clear the modifiers before `pasteClipboard()` reads them, since both callers assign `modifierState = result.modifierState` before calling `pasteClipboard()`.

Both screen callers already send the special key with the pre-dispatch state:
- `TerminalScreen.kt` around line 1039 uses `currentModifierState.terminalMods()`.
- Around line 1833 it uses `preDispatchModifierState.terminalMods()`.

So the special-key and text paths need no further changes.

### 3. Screen: consume one-shot modifiers on soft-keyboard, hardware and paste input

File: `android/app/src/main/java/com/jossephus/chuchu/ui/screens/Terminal/TerminalScreen.kt`. The modifier state lives in `var modifierState by remember { mutableStateOf(ModifierState()) }` around line 932. The `TerminalInputView` factory lambdas read and write it through the delegate, so assigning to it inside them is valid.

- **`pasteClipboard()` (around line 944):** inside the `if (text.isNotEmpty())` branch, read `val activeModifiers = modifierState`. Call `vm.onPasteText(activeModifiers.applyToText(text))`, then `modifierState = activeModifiers.consumeOneShot()`.
  - This covers both the floating "paste" button (around line 1519) and the accessory `Paste` action.
  - An empty clipboard leaves the modifiers armed, because nothing was sent.
- **`onTerminalText` (around line 1545):** inside `if (!chuchuKeys.handleText(text)) { … }`, after `vm.dispatchTextWithModifierState(text, modifierState)`, add `modifierState = modifierState.consumeOneShot()`.
  - Text consumed by the chuchu prefix keys leaves the modifiers armed.
  - A multi-character IME commit, such as an autocorrect word, still gets the modifier on every character, as it does today, and is then consumed once.
- **`onTerminalKey` (around line 1636):** inside `if (shouldForwardToTerminal)`, after `vm.onHardwareKey(...)`, add `if (action == GhosttyKeyAction.Press) modifierState = modifierState.consumeOneShot()`.
  - Hardware modifier keys never reach this callback. `KeyMapper.map` returns `null` for keycodes with `codepoint == 0` that are not in its table, and that includes the Shift, Ctrl, Alt and Meta keycodes. So every `Press` here is a real key.
  - The matching `Release` is then sent without the one-shot modifier. This is acceptable, because only the press produces terminal input.
- **Palette handler (around lines 1844–1845):** replace the comment "Preserve sticky modifiers: paste applies active modifiers but does not clear them." with "pasteClipboard() applies and consumes one-shot modifiers."
- Custom actions from the FAB (around line 1680) and the palette (around line 506) build their own state with `modifierStateForCustomAction`. They neither read nor consume `modifierState`. Leave them unchanged.
- Holding a repeatable key (for example Backspace) with a one-shot modifier armed sends the modifier on the first press only. Locking gives the repeated form. No special case is needed.

### 4. UI: long-press on modifier buttons and a locked appearance

- **`ChuButton` in `android/app/src/main/java/com/jossephus/chuchu/ui/components/ChuButton.kt`:**
  - Add the parameter `onLongClick: (() -> Unit)? = null` after `onClick`.
  - Replace `.clickable(enabled, interactionSource, indication = null, onClick = onClick)` with `.combinedClickable(enabled = enabled, interactionSource = interactionSource, indication = null, onClick = onClick, onLongClick = onLongClick)`.
  - Annotate the function with `@OptIn(ExperimentalFoundationApi::class)`, as `FileBrowserScreen.kt` line 44 does for the same API.
  - Add the imports `androidx.compose.foundation.combinedClickable` and `androidx.compose.foundation.ExperimentalFoundationApi`. Remove the `clickable` import if nothing else uses it.
  - With `onLongClick = null`, `combinedClickable` behaves like `clickable`, so existing callers are unaffected.
- **`ToggleButton` in `KeyboardAccessoryBar.kt` (around line 427):**
  - Add the parameters `locked: Boolean` and `onLongClick: () -> Unit`.
  - Pass `onLongClick = { haptics.performHapticFeedback(HapticFeedbackType.LongPress); onLongClick() }` to `ChuButton`, with `val haptics = LocalHapticFeedback.current`. Compose foundation 1.7 from BOM 2024.09.00 does not fire its own haptic on long-press.
  - Keep the label `"• $label"` and the `Filled` variant when `enabled`.
  - When `locked`, also pass `style = typography.label.copy(textDecoration = TextDecoration.Underline)` to `ChuText`, importing `androidx.compose.ui.text.style.TextDecoration`. Underlining always renders, whereas a new glyph might be missing from the font.
- **`AccessoryButton` (around line 271):** pass `locked = modifierState.isLocked(toggleModifier)` and `onLongClick = { onAction(AccessoryAction.LockModifier(toggleModifier)) }` to `ToggleButton`.
  - The settings preview in `TerminalAccessorySettings.kt` line 361 passes `onAction = {}`, so long-press there does nothing. No change is needed.

### 5. Tests: update the sticky-behaviour tests in `AccessoryLogicTest`

File: `android/app/src/test/java/com/jossephus/chuchu/ui/terminal/AccessoryLogicTest.kt`.

- **Class KDoc line 12:** change "sticky modifier persistence" to "one-shot and locked modifiers".
- **`dispatch SendSpecialKey preserves modifiers and sets suppressImeInput`:** rename it to `dispatch SendSpecialKey consumes one-shot modifiers and sets suppressImeInput`. Assert `assertFalse(r.modifierState.shift)` and delete the "sticky — preserved" comment.
- **`dispatch SendText applies modifier to text`:** rename it to `dispatch SendText applies then consumes one-shot modifier`. Assert `assertFalse(r.modifierState.ctrl)` and keep the `0x01` text assertion.
- **`dispatch Paste returns shouldPaste and preserves modifiers`:** keep the assertions. Change the comment to `// consumed by pasteClipboard, not the dispatcher`.
- Add these tests:
  - **`locked modifier survives SendText`:** start from `ModifierState().toggleLock(TerminalModifier.Ctrl)` and dispatch `SendText("a")`. Assert `r.text == "\u0001"`, `r.modifierState.ctrl` and `r.modifierState.isLocked(TerminalModifier.Ctrl)`.
  - **`consumeOneShot keeps locked and drops armed`:** start from `ModifierState(alt = true).toggleLock(TerminalModifier.Ctrl)` and call `.consumeOneShot()`. Assert `ctrl` is true and `alt` is false.
  - **`toggle and toggleLock release a locked modifier`:** with `val l = ModifierState().toggleLock(Ctrl)`, assert that `l.toggle(Ctrl)` and `l.toggleLock(Ctrl)` both have `ctrl == false` and `isLocked(Ctrl) == false`. Also assert that `ModifierState().toggle(Ctrl).toggleLock(Ctrl)` is locked, so a long-press upgrades an armed one-shot modifier.
  - **`dispatch LockModifier locks`:** dispatch `AccessoryAction.LockModifier(TerminalModifier.Alt)` on `ModifierState()`. Assert `alt` and `isLocked(Alt)`, with `text`, `specialKey` and `shouldPaste` all empty or false.

## Critical files & anchors

- `android/app/src/main/java/com/jossephus/chuchu/ui/terminal/TerminalAccessory.kt`: `ModifierState`, `AccessoryAction` and `TerminalAccessoryDispatcher.dispatch` hold all of the state logic.
- `android/app/src/main/java/com/jossephus/chuchu/ui/screens/Terminal/TerminalScreen.kt`:
  - `pasteClipboard()` around line 944.
  - `onTerminalText` and `onTerminalKey` around lines 1545–1647.
  - The palette paste comment around line 1844.
- `android/app/src/main/java/com/jossephus/chuchu/ui/terminal/KeyboardAccessoryBar.kt`: `AccessoryButton` and `ToggleButton`.
- `android/app/src/main/java/com/jossephus/chuchu/ui/components/ChuButton.kt`: the `ChuButton` click modifier.

## Verification

Run all commands from `/home/syl/Proj/p/chuchu`.

1. **Unit tests:** run `devenv shell -- bash -c 'cd android && gradle --console=plain testDebugUnitTest --tests "com.jossephus.chuchu.ui.terminal.AccessoryLogicTest"'`. All tests pass, including the four new ones.
2. **Build:** run `devenv shell -- just apk`. It ends with `BUILD SUCCESSFUL` and prints `android/app/build/outputs/apk/debug/app-debug.apk`.
3. **On a device:** no device was attached during planning (`adb devices` listed none). Connect a phone with USB debugging, run `devenv shell -- just install` and open an SSH or local shell session. Then check each case:
   - Run `cat -v`. Tap Ctrl, then type `b` on the soft keyboard. `^B` appears, and the Ctrl button returns to the outlined, unmarked style. Type `b` again and a plain `b` appears.
   - Tap Ctrl twice, then type `b`. A plain `b` appears, because the second tap cancelled Ctrl.
   - Long-press Ctrl. The label shows `• Ctrl` underlined and the phone vibrates. Type `a` then `b`, and `^A^B` appears. Tap Ctrl and the underline and fill clear. Type `c` and a plain `c` appears.
   - Tap Alt, then tap the accessory Up arrow. In `cat -v`, `^[[1;3A` appears and Alt clears.
   - Copy `x` to the clipboard, tap Ctrl, then tap the floating "paste" button. `^X` appears and Ctrl clears.
4. If no device is available, report that step 3 was not run and rely on steps 1 and 2.

## Assumptions & contingencies

- **Release and repeat events:** a one-shot modifier is consumed on the hardware or IME `Press`, not on `Release`. If testing shows a Kitty-keyboard app that needs the modifier on the release, move the consume call so it runs only when `action == GhosttyKeyAction.Release`, in the same `onTerminalKey` block.
- **`combinedClickable` OptIn:** if the compiler reports that `@OptIn(ExperimentalFoundationApi::class)` is unnecessary, remove the annotation and its import, and keep `combinedClickable`.
