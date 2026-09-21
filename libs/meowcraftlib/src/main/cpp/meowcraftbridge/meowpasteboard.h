#ifndef MEOWCRAFTBRIDGE_MEOWPASTEBOARD_H
#define MEOWCRAFTBRIDGE_MEOWPASTEBOARD_H

/*
 * Clipboard write through the platform pasteboard NDK.
 *
 * MC copies text from a few screens (the "copy link" buttons). On the GLFW path that
 * reaches the bridge through CallbackBridge.nativeClipboard, on the SDL path through the
 * ohos driver's SetClipboardText hook; both end up here.
 *
 * Returns 0 on success, -1 on failure (the NDK is resolved at run time; see the .c file).
 */
int meow_clipboard_set_text(const char *utf8);

#endif /* MEOWCRAFTBRIDGE_MEOWPASTEBOARD_H */
