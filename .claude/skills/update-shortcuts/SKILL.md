---
name: update-shortcuts
description: Register every keyboard or mouse shortcut added or changed in the current conversation in the Keyboard Shortcuts window (F1) and the status bar's modifier hints. Use after implementing or changing any shortcut (key, key combo, mouse button, wheel or drag gesture) in Majestic Media Player, before reporting the work as done.
---

# Update shortcuts in the Keyboard Shortcuts window and the status bar

Every shortcut you implemented or changed **in the current conversation** must show up in both
places below. Don't skip one because the shortcut "isn't important"; the only exception is the
status-bar rule for shortcuts without a modifier (see step 3).

## 1. List this conversation's shortcuts

Go back through the conversation and list every shortcut you added, rebound or removed:
keyboard keys, modifier combos, mouse buttons, wheel actions (including modifier+wheel) and
drag gestures. Include ones that are only reachable from the keyboard or mouse, with no menu
item. For each one, note its keys, what it does and which group it belongs to.

## 2. Keyboard Shortcuts window (`shortcutColumns` in `src/majestic.nim`)

`const shortcutColumns: array[2, seq[ShortcutGroup]]` holds the rows of the F1 window.
Each row is `("description", "keys")`.

- Put the row in the group it belongs to: File, Playback, Navigate, Subtitles, View,
  Pan, Rotate & Scale, or Mouse. Every mouse gesture goes in **Mouse**, including
  modifier+mouse ones like `Ctrl+Wheel`.
- Follow the existing style. Descriptions are sentence case ("Zoom at cursor"). Keys are
  written like `Ctrl+Shift+O`, `Numpad 5`, `Page Down`, `Click video` or `Ctrl+Wheel`.
  Pairs share one row: `("Volume up / down", "Up / Down")`.
- If you changed or removed a shortcut, update or delete its old row too.
- Keep the two columns about the same height. If one gets clearly taller, move a whole group
  to the other column instead of splitting it.

## 3. Status bar hints (`modifierHints` in `src/majestic.nim`)

While Ctrl, Shift or Alt is held, the status bar shows what that modifier combo can do.
The branches are `c and not s and not al` (Ctrl), `c and s and not al` (Ctrl+Shift),
`al and not c and not s` (Alt) and `s and not c and not al` (Shift).

- Add every shortcut that uses a modifier to the branch for its exact modifier combo, leaving
  the modifier out of the key: Ctrl+Wheel becomes `("Wheel", "Zoom At Cursor")` in the Ctrl
  branch. If a combo has no branch yet, add one.
- Hint labels are Title Case ("Open From Clipboard"). Keys are short: `Num5`, `Enter`,
  `Arrows`.
- Write mouse inputs as `LMB`, `RMB`, `MMB`, `Wheel` or `Drag` (a left-button drag). These keys
  are drawn as Blender-style mouse icons instead of key caps, and the list of them is
  `mouseIcons` in `src/icons.nim`. For a gesture none of them covers (e.g. a right-button drag),
  add an entry there: `"Key": ("mouse-<name>16", button, motion)`, where button is
  `"left"`/`"right"`/`"middle"` and motion is `""`, `"v"` or `"h"`.
- Group related hints into the same inner `@[...]`, because each inner seq is drawn as a
  separate cluster.
- Essential shortcuts go in the base `result`. View toggles and Pan/Rotate/Scale go behind
  `if all:` (the "Show all shortcuts" toggle).
- Shortcuts without a modifier (plain keys, plain clicks, middle-click, plain wheel) have no
  status-bar hint, because the bar only appears while a modifier is held. Put those in the
  F1 window only, and say in your reply to the user that they have no status-bar hint.

## 4. Menu accelerator text

If the shortcut also has a menu item in `buildMenu`, make the shortcut text shown in that item
(the second argument of `item` / `check` / `radio`) match.

## 5. Build and install

Run `make`, then `make install`, so the installed binary in `~/.local/bin` (which the user tests)
gets the changes. In your reply, list each shortcut and where you added it: the F1 window group,
the status-bar branch, or "F1 only (no modifier)".
