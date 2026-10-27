import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.viganogabriele.fast-note-todo"
  ipcTarget: "io.github.viganogabriele.fast-note-todo"
  manageIpc: false

  property var anchorItem: null
  property var host: null
  property string noteText: ""
  property string savedText: ""
  property string savePath: ""
  property string savingText: ""
  property string lookupOutput: ""
  property string lookupError: ""
  property string storageStatus: "idle"
  property string saveError: ""
  property string todoSaveError: ""
  property string loadError: ""
  property string todoLoadError: ""
  property bool loaded: false
  property bool saveQueued: false
  property bool tempWriteFailed: false

  property string viewMode: "note"
  property bool showCompleted: false
  property int selectedUid: -1
  property var completedItems: []
  // The completed entries a save in flight is going to drop, applied to the
  // list on screen only once the save succeeded. These are remembered by
  // value, not by count, so restoring one of them while the save is in
  // flight cannot make a different entry disappear in its place.
  property var pendingTrimEntries: null
  property string newTodoText: ""
  property string savedTodoJson: "{}"
  property string savingTodoJson: ""
  property string todoSavePath: ""
  property string todoLookupOutput: ""
  property string todoLookupError: ""
  property string todoStorageStatus: "idle"
  property bool todoLoaded: false
  property bool todoSaveQueued: false
  property bool todoTempWriteFailed: false

  // Drag-to-reorder state. uid identifies which row is airborne independent
  // of its live index (index keeps changing as todoModel.move() commits each
  // step), -1 means nothing is being dragged.
  property int nextTodoUid: 1
  property int draggingUid: -1
  property real dragOffsetY: 0
  property int dragStepsCommitted: 0

  // Inline text editing. -1 means no row is being edited. discardPendingEdit
  // is a one-shot flag: set right before clearing editingUid to make the
  // close discard instead of save (Escape); left false everywhere else.
  property int editingUid: -1
  property bool discardPendingEdit: false

  // Hard ceiling on what a single secret-tool lookup will hand back to the
  // long-lived shell. We're the only ones who ever write these entries, but
  // anything with Secret Service access could stuff an oversized value in —
  // head -c below keeps StdioCollector's buffer and the JSON parse that
  // follows bounded no matter what's actually stored.
  readonly property int secretReadCapBytes: 1048576

  // The largest payload that still fits into what secret-tool can store.
  // A payload without a line break is stored as it is, so it is limited by
  // what secret-tool reads from stdin; 8191 bytes is the last size that
  // does not draw its "password is too long" warning.
  readonly property int maxRawBytes: 8191

  // The largest payload that can be base64-encoded: the stored value is
  // the 12 byte "omanote-b64:" marker plus the base64 of the payload,
  // which expands it by a third, so 6132 bytes of text keeps the whole
  // value at 8188 bytes. 6135 bytes would fit exactly into 8192, but that
  // is where secret-tool starts warning, and the warning would show up as
  // a save error on a save that actually worked.
  readonly property int maxPayloadBytes: 6132

  readonly property bool dirty: noteText !== savedText
  // Whatever went wrong with the last read or save, shown in the panel so a
  // failure is never invisible (a failed read that used to be treated as an
  // empty note, or a note that was silently truncated by secret-tool, for
  // instance). Errors from both tabs are listed: a failed note save must
  // not disappear just because the to-do tab is open.
  readonly property string errorMessage: {
    var parts = []
    if (loadError) parts.push(loadError)
    if (saveError) parts.push(saveError)
    if (todoLoadError) parts.push(todoLoadError)
    if (todoSaveError) parts.push(todoSaveError)
    return parts.join(" · ")
  }
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property color foreground: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- sizing
  // Bigger and non-square on purpose (the old 217x217 box was cramped for
  // two whole views) and, in To-Do mode, adaptive to how many items exist:
  // it grows with the list up to a cap, then the inner list scrolls.
  readonly property int panelContentWidth: Style.space(300)
  readonly property int noteContentHeight: Style.space(340)
  readonly property int todoChrome: Style.space(100)
  readonly property int todoListCap: Style.space(400)
  readonly property int panelMaxHeight: Style.space(560)

  // Both views share one height: whichever naturally wants more room. A
  // panel that shrinks the moment you flip tabs feels broken, so switching
  // between Nota and To-Do never makes it smaller — only the To-Do list's
  // own item count can grow it further (up to the cap), never note the
  // other way around. The note grows the same way: vertically, with the
  // actual text, instead of ever changing width — a box that gets wider
  // while you type would jitter and need to re-center itself, which is a
  // worse feeling than a taller scratchpad that just keeps up with you.
  function fittedContentHeightFor() {
    var listHeight = root.showCompleted ? completedColumn.implicitHeight : todoColumn.implicitHeight
    var todoHeight = todoChrome + Math.min(listHeight, todoListCap)
    var noteHeight = Math.max(noteContentHeight, noteArea.implicitHeight + Style.space(20))
    // The error banner sits above the content, so it needs room of its own
    // (its height plus the gap the content area keeps below it).
    var errorHeight = storageErrorText.visible ? storageErrorText.implicitHeight + Style.space(8) + Style.space(12) : 0
    return Math.max(noteHeight, todoHeight) + errorHeight
  }

  ListModel {
    id: todoModel
  }

  function todoModelSnapshot() {
    var out = []
    for (var i = 0; i < todoModel.count; i++) {
      var it = todoModel.get(i)
      out.push({ text: it.text, done: it.done === true })
    }
    return out
  }

  function currentTodoJson() {
    return todoJsonFor(completedItems)
  }

  function todoJsonFor(completed) {
    return JSON.stringify({ mode: viewMode, items: todoModelSnapshot(), completed: completed })
  }

  function isTodoDirty() {
    return currentTodoJson() !== savedTodoJson
  }

  // Byte length of a string once it is encoded as UTF-8, which is what the
  // size limit is measured in.
  function utf8Length(text) {
    var s = String(text || "")
    try {
      return unescape(encodeURIComponent(s)).length
    } catch (e) {
      // A lone surrogate makes encodeURIComponent throw. Counting it as
      // three bytes is close enough for a size limit.
      var length = 0
      for (var i = 0; i < s.length; i++) {
        var code = s.charCodeAt(i)
        if (code < 0x80) length += 1
        else if (code < 0x800) length += 2
        else length += 3
      }
      return length
    }
  }

  // The keyring attribute stays "b.omanote" (the plugin's pre-fork id) on
  // purpose, independent of moduleName/ipcTarget above — changing it would
  // orphan whatever note is already stored under that key.
  function loadScript(field) {
    // See storeScript for why the payload is base64-encoded and tagged.
    //
    // head -c bounds how much of secret-tool's stdout we ever buffer/parse;
    // PIPESTATUS keeps the script's own exit code equal to secret-tool's
    // (not head's), so a real lookup failure still reports as an error
    // instead of looking like a successful empty read. The value is decoded
    // through a temp file so the content stays byte-exact, trailing
    // newlines included, and a value without the marker is read back
    // unchanged.
    //
    // secret-tool exits 1 when the value does not exist and says nothing in
    // that case; a run that produced an error message is a real failure.
    // Any other exit status (a signal, for instance) is a failure too, and
    // a successful run that produced no value at all is not something this
    // plugin ever stores, so it is treated as a failure as well.
    return "command -v secret-tool >/dev/null 2>&1 || { echo 'secret-tool not found' >&2; exit 127; }\n"
      + "if [ -z \"${XDG_RUNTIME_DIR:-}\" ]; then echo 'no runtime directory for the temporary file' >&2; exit 1; fi\n"
      + "umask 077\n"
      + "tmp=$(mktemp -p \"$XDG_RUNTIME_DIR\" omanote-load.XXXXXX) || exit 1\n"
      + "err=$(mktemp -p \"$XDG_RUNTIME_DIR\" omanote-load-err.XXXXXX) || { rm -f -- \"$tmp\"; exit 1; }\n"
      + "secret-tool lookup omarchy-plugin b.omanote field " + field
      + " 2> \"$err\" | head -c " + root.secretReadCapBytes + " > \"$tmp\"\n"
      + "status=${PIPESTATUS[0]}\n"
      + "if [ \"$status\" -ne 0 ]; then\n"
      + "  if [ \"$status\" -eq 1 ] && [ ! -s \"$err\" ]; then\n"
      + "    rm -f -- \"$tmp\" \"$err\"\n"
      + "    exit 0\n"
      + "  fi\n"
      + "  if [ -s \"$err\" ]; then cat -- \"$err\" >&2; fi\n"
      + "  rm -f -- \"$tmp\" \"$err\"\n"
      + "  exit \"$status\"\n"
      + "fi\n"
      + "if [ ! -s \"$tmp\" ]; then\n"
      + "  echo 'the stored value could not be read' >&2\n"
      + "  rm -f -- \"$tmp\" \"$err\"\n"
      + "  exit 1\n"
      + "fi\n"
      + "rm -f -- \"$err\"\n"
      + "if head -c 12 -- \"$tmp\" | cmp -s - <(printf %s omanote-b64:); then\n"
      + "  if ! tail -c +13 -- \"$tmp\" | base64 -d > \"$tmp.out\" 2>/dev/null; then\n"
      + "    echo 'could not decode the stored note' >&2\n"
      + "    rm -f -- \"$tmp\" \"$tmp.out\"\n"
      + "    exit 1\n"
      + "  fi\n"
      + "  if ! cat -- \"$tmp.out\"; then rm -f -- \"$tmp\" \"$tmp.out\"; exit 1; fi\n"
      + "else\n"
      + "  if ! cat -- \"$tmp\"; then rm -f -- \"$tmp\"; exit 1; fi\n"
      + "fi\n"
      + "rm -f -- \"$tmp\" \"$tmp.out\"\n"
      + "exit 0"
  }

  function storeScript(field) {
    var label = field === "todos" ? "Fast Note Todo todos" : "Fast Note Todo note"
    var what = field === "todos" ? "the to-do list" : "the note"
    // gnome-keyring writes plaintext secrets raw into the keyring file, so
    // a payload with a line break in it breaks the file's format: the
    // daemon then rejects the whole keyring ("keyring was in an invalid or
    // unrecognized format"), everything stored in it reads back empty, and
    // the Secret Service asks the user to choose a password for a new
    // keyring.
    //
    // A payload without any line break cannot break the file, so it is
    // stored as it is and keeps the full capacity. Anything with a line
    // break is base64-encoded and tagged with a marker, which keeps it on
    // a single line. The marker also tells an encoded value apart from
    // one written by an earlier version, which is read back unchanged.
    //
    // secret-tool reads at most 8192 bytes from stdin and truncates
    // anything beyond that *without failing*, so the size is checked up
    // front: an oversized payload is refused instead of silently losing
    // its tail. See maxPayloadBytes for the arithmetic of the encoded
    // path.
    return "path=$1\n"
      + "if ! command -v secret-tool >/dev/null 2>&1; then\n"
      + "  echo 'secret-tool not found' >&2\n"
      + "  rm -f -- \"$path\"\n"
      + "  exit 127\n"
      + "fi\n"
      + "size=$(wc -c < \"$path\" | tr -d ' ')\n"
      + "lines=$(wc -l < \"$path\" | tr -d ' ')\n"
      + "if [ \"$lines\" -eq 0 ] && ! head -c 12 -- \"$path\" | cmp -s - <(printf %s omanote-b64:) && ! grep -q \"$(printf '\\r')\" \"$path\"; then\n"
      + "  if [ \"$size\" -gt " + root.maxRawBytes + " ]; then\n"
      + "    echo '" + what + " is too large for the keyring (max " + root.maxRawBytes + " bytes of text)' >&2\n"
      + "    rm -f -- \"$path\"\n"
      + "    exit 1\n"
      + "  fi\n"
      + "  secret-tool store --label='" + label + "' omarchy-plugin b.omanote field " + field + " < \"$path\"\n"
      + "  status=$?\n"
      + "  rm -f -- \"$path\"\n"
      + "  exit \"$status\"\n"
      + "fi\n"
      + "if [ \"$size\" -gt " + root.maxPayloadBytes + " ]; then\n"
      + "  echo '" + what + " is too large for the keyring (max " + root.maxPayloadBytes + " bytes of text)' >&2\n"
      + "  rm -f -- \"$path\"\n"
      + "  exit 1\n"
      + "fi\n"
      + "encoded=$(base64 -w0 -- \"$path\") || { echo 'could not encode " + what + "' >&2; rm -f -- \"$path\"; exit 1; }\n"
      + "printf '%s' \"omanote-b64:$encoded\" | secret-tool store --label='" + label + "' omarchy-plugin b.omanote field " + field + "\n"
      + "status=${PIPESTATUS[1]}\n"
      + "rm -f -- \"$path\"\n"
      + "exit \"$status\""
  }

  function clearScript(field) {
    // secret-tool exits 1 when there is nothing to clear, and says nothing
    // when it does. Clearing an already empty note is not a failure worth
    // showing, so a silent exit 1 counts as success. Any other exit status
    // is a failure, even without a message: a clear that did not happen
    // must not be reported as one that did.
    return "command -v secret-tool >/dev/null 2>&1 || { echo 'secret-tool not found' >&2; exit 127; }\n"
      + "if [ -z \"${XDG_RUNTIME_DIR:-}\" ]; then echo 'no runtime directory for the temporary file' >&2; exit 1; fi\n"
      + "umask 077\n"
      + "err=$(mktemp -p \"$XDG_RUNTIME_DIR\" omanote-clear-err.XXXXXX) || exit 1\n"
      + "secret-tool clear omarchy-plugin b.omanote field " + field + " 2> \"$err\"\n"
      + "status=$?\n"
      + "if [ \"$status\" -ne 0 ]; then\n"
      + "  if [ \"$status\" -eq 1 ] && [ ! -s \"$err\" ]; then\n"
      + "    rm -f -- \"$err\"\n"
      + "    exit 0\n"
      + "  fi\n"
      + "  if [ -s \"$err\" ]; then cat -- \"$err\" >&2; fi\n"
      + "  rm -f -- \"$err\"\n"
      + "  exit \"$status\"\n"
      + "fi\n"
      + "rm -f -- \"$err\"\n"
      + "exit 0"
  }

  function tempPath() {
    if (runtimeDir === "") return ""
    return runtimeDir + "/omanote-"
      + Date.now().toString(36)
      + "-"
      + Math.floor(Math.random() * 0x100000000).toString(36)
      + ".txt"
  }

  // Just moves focus — used when flipping Nota/To-Do tabs, where jumping
  // the cursor to the end of a long note on every click would feel like a
  // jarring scroll-jump instead of a tab switch.
  function focusEditor() {
    if (root.viewMode === "todo") {
      if (!root.showCompleted) {
        root.ensureTodoSelection()
        keyScope.forceActiveFocus()
      }
    } else {
      noteArea.forceActiveFocus()
    }
  }

  function open() {
    root.controller.show()
    if (!loaded && !lookupProc.running) loadNote()
    if (!todoLoaded && !todoLookupProc.running) loadTodos()
    if (todoLoaded) pruneOldCompleted()
    Qt.callLater(function() {
      focusEditor()
      if (root.viewMode === "note") noteArea.cursorPosition = noteArea.text.length
    })
  }

  function close() {
    root.closeEditIfAny()
    saveTimer.stop()
    if (dirty) saveNow()
    todoSaveTimer.stop()
    if (isTodoDirty()) saveTodosNow()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function updateText(value) {
    noteText = String(value || "")
    // A note that was never loaded successfully must not be written back:
    // the keystrokes are shown, but nothing is saved (saveNow() bails out
    // while `loaded` is false), so a failed read can never overwrite or
    // clear the value that is still in the keyring.
    if (!loaded || storageStatus === "loading") return
    saveTimer.restart()
  }

  function loadNote() {
    lookupOutput = ""
    lookupError = ""
    storageStatus = "loading"
    lookupProc.command = ["bash", "-c", loadScript("note"), "omanote-load"]
    lookupProc.running = true
  }

  function applyLoadedText(exitCode) {
    var error = String(lookupError || "").trim()
    if (exitCode === 0) {
      var text = String(lookupOutput || "")
      noteText = text
      savedText = text
      loaded = true
      loadError = ""
      storageStatus = "ready"
      return
    }

    // The lookup failed, so we do not know what is stored. `loaded` stays
    // false, which disables the editor and stops every save: nothing can
    // overwrite or clear the stored note, and the next open retries.
    loaded = false
    loadError = error || "could not read the note from the keyring"
    storageStatus = "error"
  }

  function saveNow() {
    if (!loaded || storageStatus === "loading") return
    if (!dirty && storageStatus !== "error") return

    if (storeProc.running || clearProc.running) {
      saveQueued = true
      return
    }

    savingText = noteText
    storageStatus = "saving"
    // Cleared here rather than in finishSave(): the message belongs to the
    // attempt that produced it, so a failure from an earlier save cannot
    // survive into a later, successful one.
    saveError = ""

    if (savingText === "") {
      clearProc.command = ["bash", "-c", clearScript("note"), "omanote-clear"]
      clearProc.running = true
      return
    }

    var path = tempPath()
    if (path === "") {
      saveError = "no runtime directory for the temporary note file"
      storageStatus = "error"
      return
    }

    // Secret-tool needs EOF for multiline stdin. The transient source file
    // lives only in the user's runtime tmpfs and is deleted by storeScript().
    // It is written by Quickshell, so its mode is not ours to set; the
    // 0700 runtime directory is what keeps it out of reach.
    savePath = path
    tempWriteFailed = false
    saveFile.setText(savingText)
    if (tempWriteFailed) {
      saveError = "could not write the temporary note file"
      storageStatus = "error"
      return
    }

    storeProc.command = ["bash", "-c", storeScript("note"), "omanote-store", path]
    storeProc.running = true
  }

  function finishSave(exitCode) {
    savePath = ""

    if (exitCode === 0) {
      savedText = savingText
      storageStatus = noteText === savedText ? "ready" : "saving"
    } else {
      // A failure that produced no message still has to be visible.
      if (saveError === "") saveError = "could not save the note (secret-tool exited with " + exitCode + ")"
      storageStatus = "error"
    }

    savingText = ""

    if (saveQueued || (storageStatus !== "error" && noteText !== savedText)) {
      saveQueued = false
      Qt.callLater(saveNow)
    }
  }

  function addTodoItem() {
    // Nothing may change the list while the stored value is unknown: the
    // change would look saved in the panel but never reach the keyring.
    if (!todoLoaded) return
    var text = String(newTodoText || "").trim()
    if (text === "") return
    var uid = root.nextTodoUid++
    todoModel.append({ uid: uid, text: text, done: false })
    root.selectedUid = uid
    newTodoText = ""
    newTodoField.text = ""
    newTodoField.forceActiveFocus()
    scheduleTodoSave()
  }

  function setTodoDone(index, done) {
    if (!todoLoaded) return
    if (index < 0 || index >= todoModel.count) return
    var uid = todoModel.get(index).uid
    var wasSelected = done && root.selectedUid === uid
    var priorVisible = wasSelected ? visibleTodoUids() : null
    todoModel.setProperty(index, "done", done)
    if (wasSelected) {
      var idx = priorVisible.indexOf(uid)
      var remaining = priorVisible.filter(function(u) { return u !== uid })
      root.selectedUid = remaining.length === 0 ? -1 : remaining[Math.min(idx, remaining.length - 1)]
    }
    scheduleTodoSave()
  }

  function deleteTodoAt(index) {
    if (!todoLoaded) return
    if (index < 0 || index >= todoModel.count) return
    var uid = todoModel.get(index).uid
    if (root.editingUid === uid) root.editingUid = -1
    var wasSelected = root.selectedUid === uid
    todoModel.remove(index)
    if (wasSelected) {
      if (index < todoModel.count) root.selectedUid = todoModel.get(index).uid
      else if (todoModel.count > 0) root.selectedUid = todoModel.get(todoModel.count - 1).uid
      else root.selectedUid = -1
    }
    scheduleTodoSave()
  }

  function indexForUid(uid) {
    for (var i = 0; i < todoModel.count; i++) {
      if (todoModel.get(i).uid === uid) return i
    }
    return -1
  }

  function visibleTodoUids() {
    var out = []
    for (var i = 0; i < todoModel.count; i++) {
      var it = todoModel.get(i)
      if (!it.done) out.push(it.uid)
    }
    return out
  }

  function ensureTodoSelection() {
    var ids = visibleTodoUids()
    if (ids.indexOf(root.selectedUid) === -1) root.selectedUid = ids.length > 0 ? ids[0] : -1
  }

  function selectNextTodo() {
    var ids = visibleTodoUids()
    if (ids.length === 0) { root.selectedUid = -1; return }
    var idx = ids.indexOf(root.selectedUid)
    root.selectedUid = idx === -1 ? ids[0] : ids[Math.min(idx + 1, ids.length - 1)]
  }

  function selectPrevTodo() {
    var ids = visibleTodoUids()
    if (ids.length === 0) { root.selectedUid = -1; return }
    var idx = ids.indexOf(root.selectedUid)
    root.selectedUid = idx === -1 ? ids[0] : ids[Math.max(idx - 1, 0)]
  }

  function setTodoText(index, text) {
    if (!todoLoaded) return
    if (index < 0 || index >= todoModel.count) return
    var trimmed = String(text || "").trim()
    if (trimmed === "") return
    todoModel.setProperty(index, "text", trimmed)
    scheduleTodoSave()
  }

  // Closing an edit (for any reason — Enter, clicking a different item,
  // clicking anything else in the panel) always goes through here so the
  // in-flight text commits exactly once, in editField's onVisibleChanged.
  function beginEditTodo(uid) {
    root.editingUid = uid
  }

  function closeEditIfAny() {
    if (root.editingUid !== -1) root.editingUid = -1
  }

  function moveTodoItem(index, target) {
    if (!todoLoaded) return
    if (index < 0 || index >= todoModel.count) return
    if (target < 0 || target >= todoModel.count) return
    if (index === target) return
    todoModel.move(index, target, 1)
  }

  // Completed items age out after completedRetentionMs regardless of count —
  // a stale 20th entry sitting for weeks was more surprising than useful.
  readonly property int completedRetentionMs: 2 * 24 * 60 * 60 * 1000

  function pruneOldCompleted() {
    var cutoff = Date.now() - completedRetentionMs
    var kept = completedItems.filter(function(item) { return item.completedAt >= cutoff })
    if (kept.length !== completedItems.length) {
      completedItems = kept
      scheduleTodoSave()
    }
  }

  function removeTodoAt(index) {
    if (!todoLoaded) return
    if (index < 0 || index >= todoModel.count) return
    var removedText = todoModel.get(index).text
    todoModel.remove(index)
    if (removedText) {
      completedItems = [{ text: removedText, completedAt: Date.now() }].concat(completedItems).slice(0, 50)
    }
    scheduleTodoSave()
  }

  function restoreCompletedItem(index) {
    if (!todoLoaded) return
    if (index < 0 || index >= completedItems.length) return
    var completed = completedItems.slice()
    var entry = completed.splice(index, 1)[0]
    completedItems = completed
    todoModel.append({ uid: root.nextTodoUid++, text: entry.text, done: false })
    scheduleTodoSave()
  }

  function scheduleTodoSave() {
    if (!todoLoaded || todoStorageStatus === "loading") return
    todoSaveTimer.restart()
  }

  function loadTodos() {
    todoLookupOutput = ""
    todoLookupError = ""
    todoStorageStatus = "loading"
    todoLookupProc.command = ["bash", "-c", loadScript("todos"), "omanote-load-todos"]
    todoLookupProc.running = true
  }

  function applyLoadedTodos(exitCode) {
    var error = String(todoLookupError || "").trim()
    if (exitCode === 0) {
      var raw = String(todoLookupOutput || "")
      var parsedItems = []
      var parsedCompleted = []
      var parsedMode = root.viewMode
      var unreadable = false
      if (raw !== "") {
        try {
          var data = JSON.parse(raw)
          if (Array.isArray(data)) {
            parsedItems = data
              .filter(function(item) { return item && typeof item.text === "string" })
              .map(function(item) { return { text: item.text, done: item.done === true } })
          } else if (data && typeof data === "object") {
            if (Array.isArray(data.items)) {
              parsedItems = data.items
                .filter(function(item) { return item && typeof item.text === "string" })
                .map(function(item) { return { text: item.text, done: item.done === true } })
            } else {
              // An object without a list of items is not something this
              // plugin wrote, so it is left alone rather than replaced by
              // an empty list on the next edit.
              unreadable = true
            }
            if (Array.isArray(data.completed)) {
              // Older saves stored plain strings with no timestamp — treat
              // those as just-completed rather than dropping them outright.
              parsedCompleted = data.completed
                .map(function(entry) {
                  if (typeof entry === "string") return { text: entry, completedAt: Date.now() }
                  if (entry && typeof entry.text === "string") {
                    return { text: entry.text, completedAt: Number(entry.completedAt) || Date.now() }
                  }
                  return null
                })
                .filter(Boolean)
            }
            if (data.mode === "note" || data.mode === "todo") {
              parsedMode = data.mode
            }
          } else {
            // Neither a list nor an object: the stored value is not a
            // to-do list, so it is treated as unreadable rather than as an
            // empty list (which would overwrite it on the next edit).
            unreadable = true
          }
        } catch (e) {
          unreadable = true
        }
      }
      var cutoff = Date.now() - root.completedRetentionMs
      var beforePruneCount = parsedCompleted.length
      parsedCompleted = parsedCompleted.filter(function(entry) { return entry.completedAt >= cutoff })
      var prunedOnLoad = parsedCompleted.length !== beforePruneCount

      if (unreadable) {
        // The stored value is not a to-do list. Leave it alone rather than
        // overwriting it with an empty list on the next edit.
        todoLoaded = false
        todoLoadError = "the stored to-do list is unreadable"
        todoStorageStatus = "error"
        return
      }

      todoModel.clear()
      for (var i = 0; i < parsedItems.length; i++) {
        todoModel.append({ uid: root.nextTodoUid++, text: parsedItems[i].text, done: parsedItems[i].done === true })
      }
      completedItems = parsedCompleted
      root.viewMode = parsedMode
      todoLoaded = true
      todoLoadError = ""
      todoStorageStatus = "ready"
      root.ensureTodoSelection()
      if (prunedOnLoad) {
        // Force a save even though the in-memory state matches what we just
        // loaded — the on-disk copy still has the expired entries in it.
        savedTodoJson = ""
        scheduleTodoSave()
      } else {
        savedTodoJson = JSON.stringify({ mode: parsedMode, items: parsedItems, completed: parsedCompleted })
      }
      return
    }

    // The lookup failed, so we do not know what is stored. `todoLoaded`
    // stays false: no save can run (and therefore the stored list can
    // neither be overwritten nor cleared), and the next open retries.
    todoLoaded = false
    todoLoadError = error || "could not read the to-do list from the keyring"
    todoStorageStatus = "error"
  }

  function saveTodosNow() {
    if (!todoLoaded || todoStorageStatus === "loading") return
    if (!isTodoDirty() && todoStorageStatus !== "error") return

    if (todoStoreProc.running || todoClearProc.running) {
      todoSaveQueued = true
      return
    }

    // The payload has to fit into what secret-tool can store. The to-do
    // list is always single-line (JSON.stringify escapes the control
    // characters), so it is stored as it is and the limit is the one for
    // an unencoded payload. The oldest completed entries are dropped
    // first: they are a history buffer that is pruned anyway, and losing
    // them is better than losing the whole list. Only the entries selected
    // for trimming are remembered, so a change made while the save is in
    // flight is not thrown away with them.
    todoSaveError = ""

    var trimmed = root.completedItems
    var json = todoJsonFor(trimmed)
    while (utf8Length(json) > root.maxRawBytes && trimmed.length > 0) {
      trimmed = trimmed.slice(0, trimmed.length - 1)
      json = todoJsonFor(trimmed)
    }
    if (utf8Length(json) > root.maxRawBytes) {
      todoSaveError = "the to-do list is too large for the keyring (max " + root.maxRawBytes + " bytes of text)"
      todoStorageStatus = "error"
      return
    }
    pendingTrimEntries = root.completedItems.slice(trimmed.length)

    savingTodoJson = json
    todoStorageStatus = "saving"

    if (todoModel.count === 0 && completedItems.length === 0) {
      todoClearProc.command = ["bash", "-c", clearScript("todos"), "omanote-clear-todos"]
      todoClearProc.running = true
      return
    }

    var path = tempPath()
    if (path === "") {
      pendingTrimEntries = null
      todoSaveError = "no runtime directory for the temporary to-do file"
      todoStorageStatus = "error"
      return
    }

    todoSavePath = path
    todoTempWriteFailed = false
    todoSaveFile.setText(savingTodoJson)
    if (todoTempWriteFailed) {
      pendingTrimEntries = null
      todoSaveError = "could not write the temporary to-do file"
      todoStorageStatus = "error"
      return
    }

    todoStoreProc.command = ["bash", "-c", storeScript("todos"), "omanote-store-todos", path]
    todoStoreProc.running = true
  }

  function finishTodoSave(exitCode) {
    todoSavePath = ""

    if (exitCode === 0) {
      // The trimmed history is applied only now, so a failed save does not
      // drop entries from the list on screen. Only the entries selected for
      // trimming are dropped, and only if they are still there: an entry
      // the user restored while the save was in flight is left alone.
      if (pendingTrimEntries !== null) {
        var dropped = pendingTrimEntries
        completedItems = completedItems.filter(function(entry) {
          for (var i = 0; i < dropped.length; i++) {
            if (dropped[i].text === entry.text && dropped[i].completedAt === entry.completedAt) return false
          }
          return true
        })
      }
      pendingTrimEntries = null
      savedTodoJson = savingTodoJson
      todoStorageStatus = currentTodoJson() === savedTodoJson ? "ready" : "saving"
    } else {
      // A failure that produced no message still has to be visible.
      if (todoSaveError === "") todoSaveError = "could not save the to-do list (secret-tool exited with " + exitCode + ")"
      todoStorageStatus = "error"
    }

    savingTodoJson = ""

    if (todoSaveQueued || (todoStorageStatus !== "error" && isTodoDirty())) {
      todoSaveQueued = false
      Qt.callLater(saveTodosNow)
    }
  }

  onViewModeChanged: scheduleTodoSave()

  // Whenever an inline edit ends (Enter, Escape-discard, or a click
  // elsewhere committing it), hand keyboard focus back to the list so
  // j/k/space/e/x navigation resumes without the user having to click.
  onEditingUidChanged: {
    if (editingUid === -1 && root.viewMode === "todo" && !root.showCompleted) {
      Qt.callLater(function() { keyScope.forceActiveFocus() })
    }
  }

  onOpenedChanged: {
    if (opened) {
      if (!loaded && !lookupProc.running) loadNote()
      if (!todoLoaded && !todoLookupProc.running) loadTodos()
      Qt.callLater(function() {
        focusEditor()
        if (root.viewMode === "note") noteArea.cursorPosition = noteArea.text.length
      })
    } else {
      // Covers every way the panel can close, including a click outside it
      // that the base Panel dismisses on its own — commit any in-flight
      // edit before it's gone, so typed-but-unconfirmed text isn't lost.
      root.closeEditIfAny()
      if (dirty) {
        saveTimer.stop()
        saveNow()
      }
      if (isTodoDirty()) {
        todoSaveTimer.stop()
        saveTodosNow()
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  Timer {
    id: saveTimer
    interval: 850
    repeat: false
    onTriggered: root.saveNow()
  }

  Timer {
    id: todoSaveTimer
    interval: 850
    repeat: false
    onTriggered: root.saveTodosNow()
  }

  FileView {
    id: saveFile
    path: root.savePath
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onSaveFailed: root.tempWriteFailed = true
  }

  FileView {
    id: todoSaveFile
    path: root.todoSavePath
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onSaveFailed: root.todoTempWriteFailed = true
  }

  Process {
    id: lookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lookupOutput = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lookupError = text
    }
    onExited: function(exitCode) { root.applyLoadedText(exitCode) }
  }

  Process {
    id: storeProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.saveError = text.trim()
    }
    onExited: function(exitCode) { root.finishSave(exitCode) }
  }

  Process {
    id: clearProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.saveError = text.trim()
    }
    onExited: function(exitCode) { root.finishSave(exitCode) }
  }

  Process {
    id: todoLookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.todoLookupOutput = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.todoLookupError = text
    }
    onExited: function(exitCode) { root.applyLoadedTodos(exitCode) }
  }

  Process {
    id: todoStoreProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.todoSaveError = text.trim()
    }
    onExited: function(exitCode) { root.finishTodoSave(exitCode) }
  }

  Process {
    id: todoClearProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.todoSaveError = text.trim()
    }
    onExited: function(exitCode) { root.finishTodoSave(exitCode) }
  }

  KeyboardPanel {
    id: notePanel
    anchorItem: root.anchorItem
    owner: root.host || root
    bar: root.bar
    open: root.opened
    focusTarget: root.viewMode === "todo" ? newTodoField : noteArea
    contentWidth: notePanel.fittedContentWidth(root.panelContentWidth)
    contentHeight: notePanel.fittedContentHeight(root.fittedContentHeightFor(), root.panelMaxHeight)

    Item {
      id: keyScope
      anchors.fill: parent
      focus: true

      // Single Escape owner for the whole panel — fires before whichever
      // field has focus, so Escape reliably closes the panel regardless of
      // where the cursor happens to be. Previously each field (note, add
      // field, inline edit) handled Escape on its own; if focus had drifted
      // off all three (or landed in the inline editor, which used Escape to
      // discard instead), Escape silently did nothing.
      Keys.priority: Keys.BeforeItem
      Keys.onEscapePressed: function(event) {
        if (root.editingUid !== -1) {
          root.discardPendingEdit = true
          root.editingUid = -1
        } else if (root.viewMode === "todo" && root.showCompleted) {
          root.showCompleted = false
        } else if (root.viewMode === "todo" && newTodoField.activeFocus) {
          root.ensureTodoSelection()
          keyScope.forceActiveFocus()
        } else {
          root.close()
        }
        event.accepted = true
      }

      // Keyboard-first To-Do navigation, active only in "list mode": not
      // while typing in the add field, editing a row inline, viewing the
      // note, or browsing recently-completed — so letters like e/x/q never
      // leak into text being typed. BeforeItem priority means this fires
      // ahead of whatever currently holds focus, so the guards above are
      // what keep it from swallowing normal typing.
      Keys.onPressed: function(event) {
        if (root.viewMode !== "todo" || root.showCompleted) return
        if (root.editingUid !== -1 || newTodoField.activeFocus) return

        switch (event.key) {
        case Qt.Key_Down:
        case Qt.Key_J:
          root.selectNextTodo()
          event.accepted = true
          break
        case Qt.Key_Up:
        case Qt.Key_K:
          root.selectPrevTodo()
          event.accepted = true
          break
        case Qt.Key_Space:
          if (root.selectedUid !== -1) root.setTodoDone(root.indexForUid(root.selectedUid), true)
          event.accepted = true
          break
        case Qt.Key_E:
        case Qt.Key_Return:
        case Qt.Key_Enter:
          if (root.selectedUid !== -1) root.beginEditTodo(root.selectedUid)
          event.accepted = true
          break
        case Qt.Key_X:
        case Qt.Key_Delete:
        case Qt.Key_Backspace:
          if (root.selectedUid !== -1) root.deleteTodoAt(root.indexForUid(root.selectedUid))
          event.accepted = true
          break
        case Qt.Key_Q:
          newTodoField.forceActiveFocus()
          event.accepted = true
          break
        }
      }

      // Catches clicks that land on empty panel background (not on any row,
      // button, or field) so an open inline edit still closes there too.
      MouseArea {
        anchors.fill: parent
        enabled: root.editingUid !== -1
        onClicked: root.closeEditIfAny()
      }

      // ---------- Nota / To-Do switch ----------
      // Same equal-width segmented pattern as the Agents panel's Claude/Codex
      // provider switch: full-width cells, standard control padding.
      Row {
        id: modeSwitch
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.md

        readonly property real cellWidth: (width - spacing) / 2

        Button {
          width: modeSwitch.cellWidth
          text: "Note"
          selected: root.viewMode === "note"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: {
            root.closeEditIfAny()
            root.viewMode = "note"
            Qt.callLater(root.focusEditor)
          }
        }

        Button {
          width: modeSwitch.cellWidth
          text: "To-Do"
          selected: root.viewMode === "todo"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: {
            root.closeEditIfAny()
            root.viewMode = "todo"
            Qt.callLater(root.focusEditor)
          }
        }
      }

      PanelSeparator {
        id: headerSeparator
        anchors.top: modeSwitch.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
      }

      Text {
        id: storageErrorText
        anchors.top: headerSeparator.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.errorMessage !== ""
        text: root.errorMessage
        color: root.bar ? root.bar.urgent : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
      }

      Item {
        id: contentArea
        anchors.top: storageErrorText.visible ? storageErrorText.bottom : headerSeparator.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        QQC.ScrollView {
          id: editorScroll
          anchors.fill: parent
          visible: root.viewMode === "note"
          clip: true
          contentWidth: availableWidth
          contentHeight: Math.max(availableHeight, noteArea.implicitHeight)
          QQC.ScrollBar.vertical: QQC.ScrollBar {
            policy: QQC.ScrollBar.AlwaysOff
          }
          QQC.ScrollBar.horizontal: QQC.ScrollBar {
            policy: QQC.ScrollBar.AlwaysOff
          }

          background: null

          QQC.TextArea {
            id: noteArea
            width: editorScroll.availableWidth
            height: Math.max(editorScroll.availableHeight, implicitHeight)
            text: root.noteText
            // Loaded from the Secret Service like the todo text above; keep
            // it plain so stored markup is never rendered as rich text.
            textFormat: TextEdit.PlainText
            placeholderText: ""
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            persistentSelection: true
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            background: null
            // Editing is only possible once the stored note is known: a
            // failed read must not be turned into a write that overwrites
            // or clears whatever is in the keyring. Note that this is the
            // read state, not the save state: a save in progress or a
            // failed save must not lock the editor, or an oversized note
            // could not be shortened to make it fit again.
            enabled: root.loaded
            onTextChanged: if (text !== root.noteText) root.updateText(text)
          }
        }

        Item {
          id: todoView
          anchors.fill: parent
          visible: root.viewMode === "todo"

          Row {
            id: addRow
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.controlGap
            visible: !root.showCompleted

            TextField {
              id: newTodoField
              width: parent.width - addButton.width - historyButton.width - addRow.spacing * 2
              placeholderText: "New item…"
              text: root.newTodoText
              foreground: root.foreground
              // Same as the note: no editing while the stored list is unknown.
              enabled: root.todoLoaded
              onTextChanged: if (text !== root.newTodoText) root.newTodoText = text
              onAccepted: root.addTodoItem()
              onActiveFocusChanged: if (activeFocus) root.closeEditIfAny()
            }

            PanelActionButton {
              id: addButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "+"
              tooltipText: "Add"
              fontSize: Style.font.body
              foreground: root.foreground
              onClicked: {
                root.closeEditIfAny()
                root.addTodoItem()
              }
            }

            PanelActionButton {
              id: historyButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              tooltipText: "Recently completed"
              fontSize: Style.font.body
              foreground: root.foreground
              onClicked: {
                root.closeEditIfAny()
                root.showCompleted = true
              }
            }
          }

          PanelActionButton {
            id: backButton
            anchors.top: parent.top
            anchors.right: parent.right
            visible: root.showCompleted
            iconText: ""
            tooltipText: "Back to list"
            fontSize: Style.font.body
            foreground: root.foreground
            onClicked: {
              root.showCompleted = false
              root.ensureTodoSelection()
              Qt.callLater(function() { keyScope.forceActiveFocus() })
            }
          }

          Item {
            id: activeTodoArea
            anchors.top: addRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: !root.showCompleted

            QQC.ScrollView {
              id: todoScroll
              anchors.top: parent.top
              anchors.topMargin: Style.spacing.lg
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              clip: true
              QQC.ScrollBar.vertical.policy: todoColumn.implicitHeight > todoScroll.height ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff
              QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

              background: null

              Binding {
                target: todoScroll.contentItem
                property: "interactive"
                value: todoColumn.implicitHeight > todoScroll.height
              }

              Column {
                id: todoColumn
                width: todoScroll.availableWidth
                spacing: Style.spacing.rowGap

                  Repeater {
                    model: todoModel

                  delegate: Item {
                    id: todoRow
                    required property int uid
                    required property string text
                    required property bool done
                    required property int index

                    readonly property bool isDone: done === true
                    readonly property bool isDragging: root.draggingUid === todoRow.uid
                    readonly property bool isEditing: root.editingUid === todoRow.uid
                    readonly property bool isSelected: root.selectedUid === todoRow.uid

                    width: parent.width
                    height: (isDone && !isDragging) ? 0 : rowCard.implicitHeight
                    opacity: (isDone && !isDragging) ? 0 : 1
                    clip: !isDragging
                    z: isDragging ? 1000 : 0

                    transform: Translate {
                      y: todoRow.isDragging ? root.dragOffsetY : 0
                    }

                    Behavior on height {
                      enabled: !todoRow.isDragging
                      NumberAnimation { duration: 220; easing.type: Easing.InOutQuad }
                    }
                    Behavior on opacity { NumberAnimation { duration: 220 } }

                    Timer {
                      interval: 230
                      running: todoRow.isDone && !todoRow.isDragging
                      onTriggered: root.removeTodoAt(todoRow.index)
                    }

                    Rectangle {
                      id: rowCard
                      width: parent.width
                      implicitHeight: rowContent.implicitHeight + Style.spacing.md * 2
                      height: implicitHeight
                      radius: Style.cornerRadius
                      // Same fill vocabulary as the rest of the shell (see
                      // qs.Ui.CursorSurface): a hot row (mouse-hovered or
                      // airborne while dragging) gets the transient hover
                      // tint; the keyboard-selected row gets the persistent
                      // "current" tint instead of a hard-edged border, so it
                      // reads as part of the same visual language as every
                      // other panel rather than a focus outline slapped on.
                      readonly property bool isHot: (rowMouse.containsMouse || todoRow.isDragging) && !todoRow.isDone
                      color: isHot
                        ? Style.hoverFillFor(root.foreground, Color.accent)
                        : (todoRow.isSelected && !todoRow.isEditing
                          ? Style.selectedFillFor(root.foreground, Color.accent)
                          : "transparent")
                      border.width: todoRow.isDragging ? Style.normalBorderWidth : 0
                      border.color: Color.accent

                      Behavior on color { ColorAnimation { duration: 100 } }

                      MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        // Reached for any click that isn't on the text field
                        // itself (which has its own MouseArea on top) — the
                        // checkbox/delete/drag zones fall through to here too
                        // while they're disabled during this row's own edit.
                        onClicked: {
                          root.closeEditIfAny()
                          root.selectedUid = todoRow.uid
                        }
                      }

                      Row {
                        id: rowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        spacing: Style.spacing.md

                        BorderSurface {
                          id: checkbox
                          width: Style.space(16)
                          height: Style.space(16)
                          radius: Math.max(2, Style.cornerRadius / 2)
                          anchors.verticalCenter: parent.verticalCenter
                          color: todoRow.isDone ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
                          borderSpec: todoRow.isDone
                            ? Border.controlSpec("selected", root.foreground, Color.accent)
                            : Border.controlSpec("normal", root.foreground, Color.accent)

                          Behavior on color { ColorAnimation { duration: 150 } }

                          Text {
                            anchors.centerIn: parent
                            text: "✓"
                            color: Style.selectedStateColor(root.foreground, Color.accent)
                            font.family: root.fontFamily
                            font.pixelSize: Math.round(checkbox.height * 0.8)
                            font.bold: true
                            scale: todoRow.isDone ? 1 : 0.4
                            opacity: todoRow.isDone ? 1 : 0

                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                          }

                          MouseArea {
                            anchors.fill: parent
                            anchors.margins: -Style.spacing.xxs
                            enabled: !todoRow.isDone && !todoRow.isEditing
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              root.selectedUid = todoRow.uid
                              root.closeEditIfAny()
                              root.setTodoDone(todoRow.index, true)
                            }
                          }
                        }

                        Item {
                          id: textSlot
                          anchors.verticalCenter: parent.verticalCenter
                          width: rowContent.width - checkbox.width - deleteButton.width - dragHandle.width - rowContent.spacing * 3
                          height: Math.max(displayText.implicitHeight, editField.implicitHeight)
                          clip: true

                          Text {
                            id: displayText
                            visible: !todoRow.isEditing
                            anchors.verticalCenter: parent.verticalCenter
                            width: textSlot.width
                            text: todoRow.text
                            // Stored todo text is untrusted (it round-trips through
                            // the Secret Service and can be edited by anything with
                            // access to it) — force plain text so markup can't be
                            // interpreted as rich text and fetch external resources.
                            textFormat: Text.PlainText
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.Wrap

                            MouseArea {
                              anchors.fill: parent
                              enabled: !todoRow.isDone
                              cursorShape: Qt.IBeamCursor
                              onClicked: {
                                root.selectedUid = todoRow.uid
                                root.beginEditTodo(todoRow.uid)
                              }
                            }
                          }

                          TextField {
                            id: editField
                            // Whatever made this field stop being visible — Enter,
                            // another item taking over the edit slot, a click
                            // anywhere else in the panel, or Escape via the
                            // panel-wide key catcher below — lands here exactly
                            // once and commits, unless root.discardPendingEdit
                            // was set first (Escape discards instead of saving).
                            visible: todoRow.isEditing
                            anchors.verticalCenter: parent.verticalCenter
                            width: textSlot.width
                            text: todoRow.text
                            foreground: root.foreground
                            font.pixelSize: Style.font.bodySmall

                            onVisibleChanged: {
                              if (visible) {
                                forceActiveFocus()
                                selectAll()
                              } else {
                                if (!root.discardPendingEdit) root.setTodoText(todoRow.index, text)
                                root.discardPendingEdit = false
                              }
                            }
                            onAccepted: root.editingUid = -1
                          }
                        }

                        PanelActionButton {
                          id: deleteButton
                          anchors.verticalCenter: parent.verticalCenter
                          iconText: "✕"
                          tooltipText: "Delete"
                          fontSize: Style.font.body
                          foreground: root.foreground
                          hoverColor: root.bar ? root.bar.urgent : Color.urgent
                          onClicked: {
                            root.closeEditIfAny()
                            root.deleteTodoAt(todoRow.index)
                          }
                        }

                        Item {
                          id: dragHandle
                          width: Style.space(20)
                          height: Style.space(20)
                          anchors.verticalCenter: parent.verticalCenter

                          Text {
                            anchors.centerIn: parent
                            // The braille glyph's ink sits noticeably above the
                            // true center of its own em-box in this font; nudge
                            // it down to match the checkbox/delete icon's line.
                            anchors.verticalCenterOffset: Style.space(2)
                            text: "⠿"
                            color: todoRow.isDragging ? Color.accent : Qt.darker(root.foreground, 1.4)
                            font.pixelSize: Style.font.body
                            font.family: root.fontFamily
                          }

                          MouseArea {
                            id: dragMouse
                            anchors.fill: parent
                            enabled: !todoRow.isDone && !todoRow.isEditing
                            cursorShape: Qt.SizeVerCursor
                            preventStealing: true

                            property real pressGlobalY: 0

                            onPressed: function(mouse) {
                              root.closeEditIfAny()
                              root.selectedUid = todoRow.uid
                              pressGlobalY = mapToItem(todoColumn, 0, mouse.y).y
                              root.draggingUid = todoRow.uid
                              root.dragOffsetY = 0
                              root.dragStepsCommitted = 0
                            }

                            onPositionChanged: function(mouse) {
                              if (root.draggingUid !== todoRow.uid) return
                              var globalY = mapToItem(todoColumn, 0, mouse.y).y
                              var totalDelta = globalY - pressGlobalY
                              var rowStep = rowCard.height + todoColumn.spacing
                              if (rowStep <= 0) return
                              var desiredSteps = Math.round(totalDelta / rowStep)
                              var guard = 0
                              while (desiredSteps !== root.dragStepsCommitted && guard < 50) {
                                var dir = desiredSteps > root.dragStepsCommitted ? 1 : -1
                                var newIndex = todoRow.index + dir
                                if (newIndex < 0 || newIndex >= todoModel.count) break
                                root.moveTodoItem(todoRow.index, newIndex)
                                root.dragStepsCommitted += dir
                                guard++
                              }
                              root.dragOffsetY = totalDelta - root.dragStepsCommitted * rowStep
                            }

                            function endDrag() {
                              root.draggingUid = -1
                              root.dragOffsetY = 0
                              root.dragStepsCommitted = 0
                              root.scheduleTodoSave()
                            }

                            onReleased: endDrag()
                            onCanceled: endDrag()
                          }
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: todoModel.count === 0
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.spacing.xxl
                  text: "No items"
                  color: Qt.darker(root.foreground, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Item {
            id: completedArea
            anchors.top: backButton.bottom
            anchors.topMargin: Style.spacing.lg
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.showCompleted

            QQC.ScrollView {
              id: completedScroll
              anchors.fill: parent
              clip: true
              QQC.ScrollBar.vertical.policy: completedColumn.implicitHeight > completedScroll.height ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff
              QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

              background: null

              Binding {
                target: completedScroll.contentItem
                property: "interactive"
                value: completedColumn.implicitHeight > completedScroll.height
              }

              Column {
                id: completedColumn
                width: completedScroll.availableWidth
                spacing: Style.spacing.rowGap

                Repeater {
                  model: root.completedItems

                  delegate: Item {
                    id: completedRow
                    required property var modelData
                    required property int index
                    width: parent.width
                    height: completedCard.implicitHeight

                    RectangularShadow {
                      anchors.fill: completedCard
                      visible: completedMouse.containsMouse
                      radius: completedCard.radius
                      blur: 8
                      spread: 0
                      offset: Qt.vector2d(0, 1)
                      color: Qt.rgba(0, 0, 0, 0.35)
                      z: -1
                    }

                    Rectangle {
                      id: completedCard
                      width: parent.width
                      implicitHeight: completedRowContent.implicitHeight + Style.spacing.md * 2
                      height: implicitHeight
                      radius: Style.cornerRadius
                      color: completedMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                      Behavior on color { ColorAnimation { duration: 100 } }

                      MouseArea {
                        id: completedMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                      }

                      Row {
                        id: completedRowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        spacing: Style.spacing.md

                        PanelActionButton {
                          id: restoreButton
                          anchors.verticalCenter: parent.verticalCenter
                          iconText: "↺"
                          tooltipText: "Restore"
                          fontSize: Style.font.bodySmall
                          foreground: root.foreground
                          onClicked: root.restoreCompletedItem(completedRow.index)
                        }

                        Text {
                          text: completedRow.modelData.text
                          // Same untrusted-stored-text sink as the active list
                          // above — keep it plain, never rich text.
                          textFormat: Text.PlainText
                          color: Qt.darker(root.foreground, 1.4)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.strikeout: true
                          wrapMode: Text.Wrap
                          anchors.verticalCenter: parent.verticalCenter
                          width: completedRowContent.width - restoreButton.width - completedRowContent.spacing
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: root.completedItems.length === 0
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.spacing.xxl
                  text: "No recently completed items"
                  color: Qt.darker(root.foreground, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }
      }
    }
  }
}
