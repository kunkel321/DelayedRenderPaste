#SingleInstance
#Requires AutoHotkey v2+

/*
================================================================================
  DelayedRenderPaste.ahk - Reliable clipboard pasting for AutoHotkey v2
        Made by Claude AI, Prompted by kunkel321, 11-11-2026 
================================================================================

  THE PROBLEM
  -----------
  The usual way to paste text from a script is:

      A_Clipboard := "some text"
      Send "^v"
      A_Clipboard := oldClipboard     ; restore

  But Send "^v" only *queues* a keystroke. The target app reads the clipboard
  whenever it gets around to processing that keystroke, which might be a few
  milliseconds later or a few hundred. If the script changes the clipboard
  before then (restoring the old contents, or setting the next string), the
  app pastes the wrong thing. Slower apps such as Outlook show this a lot.

  The common fix is a Sleep after ^v, but that is a guess. Too short and it
  still fails, too long and everything is slow.

  Polling GetOpenClipboardWindow() to "see" the app reading the clipboard
  doesn't work either: apps open, read and close the clipboard in
  microseconds, so a polling loop almost never catches it.

  THE SOLUTION: DELAYED RENDERING
  -------------------------------
  Windows lets a program put a *promise* on the clipboard instead of data:
  "I have Unicode text, ask me when you need it." This is done by calling
  SetClipboardData with a NULL data handle.

  When any app then tries to read that text, Windows sends the clipboard
  owner (this script) a WM_RENDERFORMAT message, and the script hands over
  the real data at that moment.

  That message is exactly the signal we want: it means "the app is reading
  the clipboard right now." Only after it arrives does the script move on
  to the next string, or restore the user's original clipboard.

  USAGE
  -----
      DRPaste.Paste("one string")
      DRPaste.Paste("first", "second", "third")    ; any number, in order

  Returns true if every string was picked up by the target app, false if
  one wasn't (in which case it stops there rather than paste out of order).
  DRPaste.timings holds how many ms after each ^v the app asked for the text.

  Untested beyond Notepad, Word and Outlook (classic). Other apps may behave
  differently, especially ones that read the clipboard more than once per
  paste.
================================================================================
*/

; ------------------------------------------------------------------------------
; By default, a new AHK thread (such as a hotkey) can't be interrupted for its
; first 15 ms. The paste target may ask for the clipboard text within that
; window, and if our WM_RENDERFORMAT handler can't run, the app gets nothing
; (an empty paste). Setting this to 0 makes new threads interruptible at once.
; This must be in the auto-execute section (top of the script) to take effect.
; ------------------------------------------------------------------------------
Thread "Interrupt", 0


; ------------------------------------------------------------------------------
; Demo hotkey: Ctrl+2 pastes four lines, then types the timing info after them.
; ------------------------------------------------------------------------------
^2:: {
    var1 := "Clipboard text one.`n"
    var2 := "Clipboard text two.`n"
    var3 := "Clipboard text three.`n"
    var4 := "Clipboard text four.`n"

    start := A_TickCount
    ok := DRPaste.Paste(var1, var2, var3, var4)
    total := A_TickCount - start

    ; Build the debug report. Each timing is how long after its ^v the app
    ; asked for the text (i.e., how long it took the app to start pasting).
    report := ""
    for i, ms in DRPaste.timings
        report .= "#" i ": " ms " ms`n"
    if ok
        report .= "Total: " total " ms`n"
    else
        report .= "Stopped: item " (DRPaste.timings.Length + 1) " was never requested`n"

    ; SendText types the text literally (no hotkey symbols like ^ or + get
    ; interpreted), and each `n is sent as Enter, so the report appears as
    ; separate lines right after the pasted text. Typing is fine here since
    ; this is just debug output and doesn't use the clipboard at all.
    SendText report
}


; ==============================================================================
;  DRPaste class
;  All members are static, so there's no need to create an instance:
;  just call DRPaste.Paste(...).
; ==============================================================================
class DRPaste {
    ; State shared between Paste/PasteOne and the message handlers.
    static text     := ""      ; the string currently promised on the clipboard
    static rendered := false   ; set true by OnRender when the app asks for it
    static sendTick := 0       ; A_TickCount when ^v was sent (for timings)
    static timings  := []      ; ms from ^v to request, one entry per string

    ; --------------------------------------------------------------------------
    ; Static __New runs once, automatically, the first time the class is used.
    ; --------------------------------------------------------------------------
    static __New() {
        ; Ask AHK to call our methods when these messages reach the script's
        ; hidden main window (A_ScriptHwnd), which is the clipboard owner.
        ;   WM_RENDERFORMAT     (0x305): an app wants the promised data now.
        ;   WM_RENDERALLFORMATS (0x306): the script is exiting while it still
        ;                                owns promised data; hand it over so it
        ;                                isn't lost.
        OnMessage(0x305, ObjBindMethod(this, "OnRender"))
        OnMessage(0x306, ObjBindMethod(this, "OnRenderAll"))

        ; Clipboard "hint" formats. Clipboard listeners (Windows clipboard
        ; history / Win+V, cloud clipboard, Ditto and others) normally read
        ; new clipboard content the moment it appears. That read would fire
        ; WM_RENDERFORMAT *before* the real paste and fool our signal.
        ; These formats tell well-behaved listeners to leave the content alone:
        ;   ExcludeClipboardContentFromMonitorProcessing - general "ignore me"
        ;   CanIncludeInClipboardHistory                 - keep out of Win+V
        ;   CanUploadToCloudClipboard                    - don't sync to cloud
        ;   Clipboard Viewer Ignore                      - Ditto and similar
        ; Side benefit: these pastes don't clutter the user's clipboard history.
        ; RegisterClipboardFormat returns the same ID for a given name in every
        ; process, which is how other programs recognize them.
        this.skipFmts := []
        for name in ["ExcludeClipboardContentFromMonitorProcessing"
                   , "CanIncludeInClipboardHistory"
                   , "CanUploadToCloudClipboard"
                   , "Clipboard Viewer Ignore"]
            this.skipFmts.Push(DllCall("RegisterClipboardFormat", "Str", name, "UInt"))
    }

    ; --------------------------------------------------------------------------
    ; Paste one or more strings in order, then restore the user's clipboard.
    ; --------------------------------------------------------------------------
    static Paste(texts*) {
        this.timings := []

        ; Save the user's clipboard once (all formats: text, images, files...).
        bak := ClipboardAll()

        ok := true
        for text in texts {
            ; Stop at the first string the app never asked for. Carrying on
            ; could paste the remaining strings in the wrong order.
            if !(ok := this.PasteOne(text))
                break
        }

        ; Restore the user's clipboard. If the target app is still in the
        ; middle of reading the last string (clipboard still open), AHK keeps
        ; retrying for up to A_ClipboardTimeout (default 1000 ms), so this
        ; won't clobber a paste in progress.
        A_Clipboard := bak
        return ok
    }

    ; --------------------------------------------------------------------------
    ; Promise one string on the clipboard, send ^v, and wait until the target
    ; app actually asks for it. Returns true if it did within the timeout.
    ; --------------------------------------------------------------------------
    static PasteOne(text, timeout := 3000) {
        ; Windows clipboard text is expected to use CRLF line endings. Notepad
        ; accepts a bare `n, but Outlook (and some other apps) ignore it, which
        ; is why everything ended up on one line there. Normalize every line
        ; ending to `r`n: first turn existing `r`n into `n so they don't
        ; become `r`r`n, then turn every `n into `r`n.
        this.text := StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "`r`n")
        this.rendered := false

        ; Open the clipboard with our script window as the owner. Only one
        ; program can have it open at a time, so if the app is still reading
        ; the previous string, this fails and we retry. That retry is what
        ; keeps us from changing the clipboard during the previous paste.
        t0 := A_TickCount
        while !DllCall("OpenClipboard", "Ptr", A_ScriptHwnd) {
            if (A_TickCount - t0) > 1000
                return false        ; someone is hogging the clipboard
            Sleep 5
        }

        ; EmptyClipboard clears it and makes our window the owner, which is
        ; required for Windows to send us WM_RENDERFORMAT later.
        DllCall("EmptyClipboard")

        ; The promise: format 13 (CF_UNICODETEXT) with a NULL handle = "I have
        ; Unicode text, ask me for it." Apps asking for plain CF_TEXT also
        ; work, because Windows converts from CF_UNICODETEXT automatically
        ; (and asks us to render it first).
        DllCall("SetClipboardData", "UInt", 13, "Ptr", 0)

        ; The hint formats get real data (not a promise), since we don't want
        ; anyone asking us to render them. Their content doesn't matter, so
        ; each gets a 4-byte zero-filled block. GlobalAlloc flag 0x42 = GHND
        ; (movable + zero-initialized), which is what the clipboard expects.
        ; Once given to SetClipboardData, the memory belongs to Windows and
        ; must not be freed by us.
        for fmt in this.skipFmts
            DllCall("SetClipboardData", "UInt", fmt
                  , "Ptr", DllCall("GlobalAlloc", "UInt", 0x42, "UPtr", 4, "Ptr"))

        ; Close it so the target app can open it when it processes ^v.
        DllCall("CloseClipboard")

        this.sendTick := A_TickCount
        Send "^v"

        ; Wait for OnRender to flip this.rendered. AHK's Sleep keeps
        ; processing window messages, so OnRender can run during this loop.
        while !this.rendered && (A_TickCount - this.sendTick) < timeout
            Sleep 5
        return this.rendered
    }

    ; --------------------------------------------------------------------------
    ; WM_RENDERFORMAT handler: an app is reading the clipboard right now and
    ; wants the text we promised. wParam is the clipboard format it asked for.
    ; --------------------------------------------------------------------------
    static OnRender(wParam, lParam, msg, hwnd) {
        if (wParam != 13)   ; we only promised CF_UNICODETEXT
            return          ; (returning nothing = let AHK/Windows handle it)

        ; The requesting app already has the clipboard open, so we must NOT
        ; call OpenClipboard here. Just supply the data.
        DllCall("SetClipboardData", "UInt", 13, "Ptr", this.MakeText(this.text))

        ; Record the timing once per string, then signal PasteOne to move on.
        if !this.rendered
            this.timings.Push(A_TickCount - this.sendTick)
        this.rendered := true
        return 0            ; 0 = message handled
    }

    ; --------------------------------------------------------------------------
    ; WM_RENDERALLFORMATS handler: the script is closing while the clipboard
    ; still holds an unfulfilled promise of ours. Supply the data now so the
    ; clipboard isn't left empty. (Rare: normally Paste() restores the user's
    ; clipboard before this could happen.)
    ; --------------------------------------------------------------------------
    static OnRenderAll(wParam, lParam, msg, hwnd) {
        ; Unlike OnRender, here we must open the clipboard ourselves.
        if !DllCall("OpenClipboard", "Ptr", A_ScriptHwnd)
            return 0
        ; Only supply data if we're still the owner (someone else may have
        ; replaced the clipboard contents in the meantime).
        if (DllCall("GetClipboardOwner", "Ptr") = A_ScriptHwnd)
            DllCall("SetClipboardData", "UInt", 13, "Ptr", this.MakeText(this.text))
        DllCall("CloseClipboard")
        return 0
    }

    ; --------------------------------------------------------------------------
    ; Copy a string into a block of global memory in UTF-16, the form the
    ; clipboard requires for CF_UNICODETEXT. Returns the memory handle.
    ; --------------------------------------------------------------------------
    static MakeText(s) {
        ; StrPut with no buffer returns the length in characters, including
        ; the terminating null. UTF-16 uses 2 bytes per character.
        bytes := StrPut(s, "UTF-16") * 2
        hMem := DllCall("GlobalAlloc", "UInt", 0x42, "UPtr", bytes, "Ptr")  ; GHND
        p := DllCall("GlobalLock", "Ptr", hMem, "Ptr")   ; get a usable pointer
        StrPut(s, p, "UTF-16")                           ; write the string
        DllCall("GlobalUnlock", "Ptr", hMem)
        return hMem          ; ownership passes to Windows via SetClipboardData
    }
}
