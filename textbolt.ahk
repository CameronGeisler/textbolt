; TextBolt: a tiny text expander. Each snippets\<folder>\<name>.txt becomes the shortcut /<name>.
#Requires AutoHotkey v2.0
#SingleInstance Force
FileEncoding "UTF-8"

SnippetDir := A_ScriptDir "\snippets"
Snippets := []          ; [{name, folder, text, path}]
LastWin := 0            ; the window you were typing in, so Search can insert there
DirCreate SnippetDir

LoadSnippets()
BuildTray()
BuildSearch()
WatchSig := Signature()
SetTimer(WatchSnippets, 2000)
; Remember the last real app window you used. Clicking the tray icon focuses the taskbar,
; so asking "which window is active?" at that moment would give the wrong answer.
DllCall("RegisterShellHookWindow", "Ptr", A_ScriptHwnd)
OnMessage(DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt"), OnShell)

^+Space::ShowSearch()

LoadSnippets() {
    global Snippets
    Loop Files SnippetDir "\*.txt", "R" {
        name := SubStr(A_LoopFileName, 1, -4)
        text := StrReplace(FileRead(A_LoopFileFullPath), "`r`n", "`n")
        folder := (A_LoopFileDir = SnippetDir) ? "" : SubStr(A_LoopFileDir, StrLen(SnippetDir) + 2)
        Snippets.Push({name: name, folder: folder, text: text, path: A_LoopFileFullPath})
        ; * = fire as soon as the shortcut is typed, ? = fire even right after other text (like Text Blaze)
        Hotstring(":*?:/" name, InsertText.Bind(text))
    }
}

; Paste via the clipboard (instant for long text, keeps unicode), then restore what was there.
InsertText(text, *) {
    saved := ClipboardAll()
    A_Clipboard := StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "`r`n")
    if !ClipWait(1)
        return
    Send "^v"
    Sleep 500           ; give the app time to read the clipboard before restoring it
    A_Clipboard := saved
}

BuildTray() {
    if FileExist(A_ScriptDir "\textbolt.ico")
        TraySetIcon(A_ScriptDir "\textbolt.ico")
    A_IconTip := "TextBolt (" Snippets.Length " snippets)"
    m := A_TrayMenu
    m.Delete()
    m.Add("Search snippets`tCtrl+Shift+Space", (*) => ShowSearch())
    m.Add("Open snippets folder", (*) => Run(SnippetDir))
    m.Add()
    m.Add("Pause", TogglePause)
    m.Add("Reload", (*) => Reload())
    m.Add("Exit", (*) => ExitApp())
    m.Default := "Search snippets`tCtrl+Shift+Space"
    m.ClickCount := 1   ; single left-click on the tray icon opens search
}

TogglePause(item, pos, menu) {
    Suspend -1
    menu.ToggleCheck(item)
    A_IconTip := A_IsSuspended ? "TextBolt (paused)" : "TextBolt (" Snippets.Length " snippets)"
}

; ---- Search window: type to filter, Enter inserts; click a snippet to edit it below ----
BuildSearch() {
    global SearchGui, SearchBox, SearchList, Editor, EditingName := ""
    SearchGui := Gui("+AlwaysOnTop -MinimizeBox", "TextBolt")
    SearchGui.SetFont("s11", "Segoe UI")
    SearchBox := SearchGui.Add("Edit", "w700")
    SendMessage(0x1501, true, StrPtr("Search, or type a new shortcut name and click New"), SearchBox)  ; gray hint text
    SearchBox.OnEvent("Change", (*) => FillList())
    SearchList := SearchGui.Add("ListView", "w700 r8 -Multi", ["Shortcut", "Folder", "Text"])
    SearchList.OnEvent("DoubleClick", (*) => PickSelected())
    SearchList.OnEvent("ItemSelect", (lv, row, selected) => selected && LoadEditor(row))
    Editor := SearchGui.Add("Edit", "w700 r12 Multi WantReturn WantTab")
    SearchGui.Add("Button", "w90", "Save").OnEvent("Click", (*) => SaveEditor())
    SearchGui.Add("Button", "x+8 w90", "New").OnEvent("Click", (*) => NewSnippet())
    SearchGui.Add("Button", "Default Hidden", "OK").OnEvent("Click", (*) => PickSelected())
    SearchGui.OnEvent("Escape", (*) => HideSearch())
    SearchGui.OnEvent("Close", (*) => HideSearch())
}

; True for a normal app window: not TextBolt itself, not the taskbar or tray.
IsAppWindow(hwnd) {
    if !hwnd || hwnd = SearchGui.Hwnd || hwnd = A_ScriptHwnd
        return false
    try return !(WinGetClass(hwnd) ~= "^(Shell_TrayWnd|Shell_SecondaryTrayWnd|NotifyIconOverflowWindow|TopLevelWindowForOverflowXamlIsland)$")
    return false
}

OnShell(event, hwnd, *) {
    global LastWin
    if (event = 4 || event = 0x8004) && IsAppWindow(hwnd)   ; 4 = a window was activated
        LastWin := hwnd
}

ShowSearch() {
    global LastWin
    if IsAppWindow(WinExist("A"))
        LastWin := WinExist("A")
    SearchBox.Value := ""
    FillList()
    SearchGui.Show()
    SearchBox.Focus()
}

HideSearch() {
    SaveEditor()
    SearchGui.Hide()
}

FillList(select := "") {
    global EditingName
    q := SearchBox.Value
    SearchList.Delete()
    for s in Snippets
        if (q = "" || InStr(s.name, q) || InStr(s.folder, q) || InStr(s.text, q))
            SearchList.Add(, "/" s.name, s.folder, SubStr(RegExReplace(s.text, "\s+", " "), 1, 90))
    SearchList.ModifyCol(1, 90), SearchList.ModifyCol(2, 120), SearchList.ModifyCol(3, 470)
    row := 1
    Loop SearchList.GetCount()
        if (SearchList.GetText(A_Index, 1) = "/" select)
            row := A_Index
    if SearchList.GetCount()
        SearchList.Modify(row, "Select Focus Vis"), LoadEditor(row)   ; ItemSelect doesn't fire for this, so load directly
    else
        SaveEditor(), Editor.Value := "", EditingName := ""
}

FindSnippet(name) {
    for s in Snippets
        if (s.name = name)
            return s
}

LoadEditor(row) {
    global EditingName
    SaveEditor()                      ; never lose edits when switching snippets
    EditingName := SubStr(SearchList.GetText(row, 1), 2)
    Editor.Value := StrReplace(FindSnippet(EditingName).text, "`n", "`r`n")
}

SaveEditor() {
    global WatchSig
    if (EditingName = "" || !(s := FindSnippet(EditingName)))
        return
    text := StrReplace(Editor.Value, "`r`n", "`n")
    if (text == s.text)
        return
    f := FileOpen(s.path, "w", "UTF-8-RAW")
    f.Write(text), f.Close()
    s.text := text
    Hotstring(":*?:/" s.name, InsertText.Bind(text))
    WatchSig := Signature()           ; our own save shouldn't trigger a reload
}

; Creates the shortcut typed in the search box (e.g. "hello" makes /hello), in the selected snippet's folder.
NewSnippet() {
    SaveEditor()
    name := Trim(SearchBox.Value, " /")
    if (name = "" || RegExMatch(name, "[\\/:*?`"<>|\s]"))
        return MsgBox("Type the new shortcut name in the search box first (e.g. hello for /hello), then click New.", "TextBolt")
    if FindSnippet(name)
        return MsgBox("/" name " already exists.", "TextBolt")
    cur := FindSnippet(EditingName)
    folder := cur ? cur.folder : ""
    dir := SnippetDir (folder = "" ? "" : "\" folder)
    DirCreate dir
    path := dir "\" name ".txt"
    FileAppend "", path, "UTF-8-RAW"
    Snippets.Push({name: name, folder: folder, text: "", path: path})
    Hotstring(":*?:/" name, InsertText.Bind(""))
    global WatchSig := Signature()
    SearchBox.Value := name
    FillList(name)
    Editor.Focus()
}

PickSelected() {
    SaveEditor()
    if !SearchList.GetCount()
        return
    s := FindSnippet(SubStr(SearchList.GetText(SearchList.GetNext() || 1, 1), 2))
    SearchGui.Hide()
    if LastWin && WinExist("ahk_id " LastWin) {
        WinActivate("ahk_id " LastWin)
        WinWaitActive("ahk_id " LastWin, , 1)
    }
    InsertText(s.text)
}

; In the search window: Up/Down in the search box move the list selection, Ctrl+S saves.
#HotIf WinActive("ahk_id " SearchGui.Hwnd)
^s::SaveEditor()
#HotIf WinActive("ahk_id " SearchGui.Hwnd) && SearchGui.FocusedCtrl = SearchBox
Up::MoveSel(-1)
Down::MoveSel(1)
#HotIf

MoveSel(d) {
    n := SearchList.GetCount()
    if !n
        return
    row := Max(1, Min(n, (SearchList.GetNext() || 1) + d))
    SearchList.Modify(0, "-Select")
    SearchList.Modify(row, "Select Focus Vis"), LoadEditor(row)
}

; Reload automatically when a snippet file is added, edited, or removed outside TextBolt.
Signature() {
    s := ""
    Loop Files SnippetDir "\*.txt", "R"
        s .= A_LoopFileFullPath A_LoopFileTimeModified A_LoopFileSize "|"
    return s
}

WatchSnippets() {
    global WatchSig
    if WinExist("ahk_id " SearchGui.Hwnd)   ; don't reload (and lose typing) while the window is open
        return
    if (Signature() != WatchSig)
        Reload()
}
