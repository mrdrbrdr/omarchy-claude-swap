import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// omarchy-claude-swap: bar icon + dropdown for claude-swap (Claude Code
// multi-account switching).
// Everything runs through ./cswap-bar. `json` is polled every 60 s (15 s while
// the panel is open); cswap serves `list` from its shared usage cache, so this
// adds no calls to the rate-limited usage endpoint. Actions: switch,
// threshold, auto-switch on/off, disable/enable, remove, add from this
// machine's login or a setup token, copy.
// Settings (shell.json): `machines` (default "local"; comma-separated ssh
// destinations driven together, the first is primary) and `localName` (label
// for this machine, default its hostname).
// Bar: 󰀙 <active account> <its fullest limit>%; "1|2" when machines are on
// different accounts. Urgent color at the threshold or when something is wrong.
// Left-click opens the panel. Switches and removals ask for a second click.
// Open from scripts: omarchy-shell shell toggle mrdrbrdr.claude-swap
Panel {
  id: root
  moduleName: "mrdrbrdr.claude-swap"
  ipcTarget: ""

  readonly property string glyph: "󰀙"
  readonly property string machinesSetting: String(setting("machines", "local")).replace(/\s+/g, "")
  readonly property string localName: String(setting("localName", ""))
  // Automatic rescue switch: see autoFallbackTarget().
  readonly property bool autoFallback: setting("autoFallback", true) === true
  readonly property string helper: String(Qt.resolvedUrl("cswap-bar")).replace(/^file:\/\//, "")
  readonly property var helperBase: [helper, "--machines", machinesSetting]
    .concat(localName !== "" ? ["--local-name", localName] : [])
  // More than one machine: labels say "everywhere" and the sync checks apply.
  readonly property bool multi: machinesSetting.split(",").filter(function(m) { return m !== "" }).length > 1
  readonly property string everywhereText: multi ? " everywhere" : ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- state from the last poll ----
  // machines: [{machine, host, data, unreachable, err}] from `cswap-bar json`.
  // A machine that does not answer keeps its previous data, flagged
  // unreachable, so a hiccup does not blank the panel.
  property var machines: []
  property bool pollFailed: false
  property double nowMs: Date.now()

  // ---- actions ----
  // A switch makes every running session cold-rebuild its prompt cache once it
  // picks the new token up, so switches and removals take two presses: the
  // first arms (armedKey), the second within 4 s runs.
  property string armedKey: ""
  property string actionLabel: ""
  property string actionKind: ""
  property var actionLines: []      // [{text, bad}] from the last action
  property int pendingThreshold: -1
  property bool thresholdSettling: false
  property bool manageOpen: false
  property string fallbackNote: ""
  property string pendingStdin: ""

  // ---------------------------------------------------------------- derived

  readonly property var reachable: machines.filter(function(m) { return m.data && m.data.list })
  readonly property var primary: reachable.length ? reachable[0] : null
  // This machine's entry: logins are only ever added here and copied outward.
  readonly property var localMachine: {
    for (var i = 0; i < machines.length; i++) if (machines[i].host === "local") return machines[i]
    return null
  }
  readonly property var accounts: mergeAccounts(reachable)
  readonly property var activeByMachine: reachable.map(function(m) {
    var a = activeAccountOf(m)
    return { machine: m.machine, email: a ? a.email : "", number: a ? Number(a.number) : 0 }
  })
  readonly property bool inSync: {
    var emails = {}
    for (var i = 0; i < activeByMachine.length; i++) emails[activeByMachine[i].email] = true
    return Object.keys(emails).length <= 1
  }
  readonly property var primaryActive: activeByMachine.length ? accountByEmail(activeByMachine[0].email) : null
  readonly property real activePct: primaryActive ? bindingPct(primaryActive) : -1
  readonly property real threshold: configuredThreshold(primary)
  readonly property real shownThreshold: pendingThreshold >= 0 ? pendingThreshold : threshold
  readonly property var issues: collectIssues()
  readonly property bool alarming: issues.length > 0 || activePct >= threshold
  readonly property bool autoOn: reachable.length > 0 && reachable.every(function(m) { return m.data.engine === "active" })
  readonly property bool autoMixed: !autoOn && reachable.some(function(m) { return m.data.engine === "active" })
  readonly property bool autoInstalled: reachable.length > 0 && reachable.every(function(m) { return m.data.engineUnit !== "not-found" })
  readonly property bool noAccounts: reachable.length > 0 && accounts.length === 0

  readonly property string barLabel: {
    if (!primaryActive) return glyph + " ?"
    var nums = activeByMachine.map(function(a) { return displayNumber(a.email) })
    var unique = nums.filter(function(n, i) { return nums.indexOf(n) === i })
    return glyph + " " + unique.join("|") + " " + Math.round(activePct) + "%"
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function activeAccountOf(m) {
    var list = m && m.data ? m.data.list : null
    if (!list || !Array.isArray(list.accounts)) return null
    for (var i = 0; i < list.accounts.length; i++)
      if (list.accounts[i].active === true) return list.accounts[i]
    return null
  }

  // One record per email across machines. Usage is org-wide, so the freshest
  // machine's numbers win; slot numbers come from the primary machine.
  function mergeAccounts(ms) {
    var byEmail = {}
    var order = []
    for (var i = 0; i < ms.length; i++) {
      var m = ms[i]
      var list = m.data.list.accounts || []
      for (var j = 0; j < list.length; j++) {
        var a = list[j]
        var rec = byEmail[a.email]
        if (!rec) {
          rec = { email: a.email, number: Number(a.number), alias: a.alias || "", usage: null,
                  usageStatus: "", fetchedMs: -1, on: [], activeOn: [], disabledOn: [] }
          byEmail[a.email] = rec
          order.push(a.email)
        }
        rec.on.push(m.machine)
        if (a.active === true) rec.activeOn.push(m.machine)
        if (a.disabled === true) rec.disabledOn.push(m.machine)
        var fetched = parseMs(a.usageFetchedAt)
        if (a.usage && (rec.usage === null || (isFinite(fetched) && fetched > rec.fetchedMs))) {
          rec.usage = a.usage
          rec.usageStatus = String(a.usageStatus || "ok")
          if (isFinite(fetched)) rec.fetchedMs = fetched
        } else if (!rec.usage && rec.usageStatus === "") {
          rec.usageStatus = String(a.usageStatus || "")
        }
      }
    }
    var out = order.map(function(e) { return byEmail[e] })
    out.sort(function(x, y) { return x.number - y.number })
    return out
  }

  function accountByEmail(email) {
    for (var i = 0; i < accounts.length; i++) if (accounts[i].email === email) return accounts[i]
    return null
  }
  function displayNumber(email) {
    var a = accountByEmail(email)
    return a ? (a.alias || String(a.number)) : "?"
  }
  function everywhere(list) { return reachable.every(function(m) { return list.indexOf(m.machine) >= 0 }) }
  function joinNames(list) { return list.join(" + ") }

  function configuredThreshold(m) {
    var t = m && m.data && m.data.config ? Number(m.data.config.threshold) : NaN
    if (!(t > 0) && m && m.data && m.data.lastPoll) t = Number(m.data.lastPoll.threshold)
    return t > 0 ? t : 95
  }

  // ---------------------------------------------------------------- limits

  function windowRecord(title, w) {
    return {
      title: title,
      pct: Number(w.pct),
      resetAt: String(w.resetsAt || ""),
      expected: w.expectedPct === undefined || w.expectedPct === null ? -1 : Number(w.expectedPct),
      lasts: w.willLastToReset === undefined ? null : w.willLastToReset,
      exhaustAt: String(w.projectedExhaustionAt || "")
    }
  }

  function limitsOf(a) {
    var u = a && a.usage ? a.usage : null
    if (!u) return []
    var out = []
    if (u.fiveHour) out.push(windowRecord("5-hour", u.fiveHour))
    if (u.sevenDay) out.push(windowRecord("Weekly", u.sevenDay))
    var scoped = u.scoped || []
    for (var i = 0; i < scoped.length; i++)
      out.push(windowRecord(String(scoped[i].name || "Model"), scoped[i]))
    return out
  }

  // Session + weekly only: what stops EVERY model, ignoring per-model limits.
  function accountWidePct(a) {
    var u = a && a.usage ? a.usage : null
    if (!u) return -1
    var out = -1
    if (u.fiveHour && Number(u.fiveHour.pct) > out) out = Number(u.fiveHour.pct)
    if (u.sevenDay && Number(u.sevenDay.pct) > out) out = Number(u.sevenDay.pct)
    return out
  }

  // The rescue claude-swap will not do for itself. Its engine folds the
  // per-model weekly limits into every decision, so when that model is spent
  // on every account it reports "all exhausted" and sits still, even while the
  // active account is hard blocked and another one has a free session window
  // that other models could use. Returns that account, or null.
  function autoFallbackTarget() {
    if (!autoFallback || actionProc.running || !primaryActive) return null
    // Does claude-swap still have a move of its own? Then leave it alone.
    var margin = 100 - threshold
    for (var i = 0; i < accounts.length; i++) {
      var a = accounts[i]
      if (a.disabledOn.length > 0) continue
      if (100 - bindingPct(a) > margin) return null
    }
    // Only when staying put means not working at all.
    if (accountWidePct(primaryActive) < 99) return null
    var best = null
    for (var j = 0; j < accounts.length; j++) {
      var c = accounts[j]
      if (c.email === primaryActive.email || c.disabledOn.length > 0) continue
      if (c.on.length < reachable.length) continue          // not stored everywhere
      var pct = accountWidePct(c)
      if (pct < 0 || pct >= 99) continue                    // no session room either
      if (!best || pct < accountWidePct(best)) best = c
    }
    return best
  }

  // The fullest window is the one that stops the next prompt.
  function bindingPct(a) {
    var windows = limitsOf(a)
    var best = -1
    for (var i = 0; i < windows.length; i++)
      if (windows[i].pct > best) best = windows[i].pct
    return best
  }

  // Text for an auto-formatted Qt Text that must stay plain: without < and >
  // there is no tag, so Qt never treats it as rich text (no <img> fetch).
  // Emails and machine names cannot contain them; error text shows ‹ › instead.
  function plainTooltip(s) {
    return String(s).replace(/</g, "‹").replace(/>/g, "›")
  }

  // cswap sends microsecond ISO stamps ("…:00.215949+00:00"); V4 wants them trimmed.
  function parseMs(iso) {
    if (!iso) return NaN
    return new Date(String(iso).replace(/\.\d+/, "")).getTime()
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // "15:00" today, "Tue 14:00" on any other day.
  function clockText(iso) {
    var ms = parseMs(iso)
    if (!isFinite(ms)) return ""
    var d = new Date(ms)
    var sameDay = d.toDateString() === new Date(nowMs).toDateString()
    return Qt.formatDateTime(d, sameDay ? "HH:mm" : "ddd HH:mm")
  }

  function untilText(iso) {
    var ms = parseMs(iso)
    return isFinite(ms) ? formatDuration(ms - nowMs) : ""
  }

  function limitTooltip(w) {
    if (!w) return ""
    var parts = ["Resets " + clockText(w.resetAt) + " (in " + untilText(w.resetAt) + ")"]
    if (w.expected >= 0) parts.push("an even pace would be at " + Math.round(w.expected) + "% by now")
    if (w.lasts === true) parts.push("lasts until the reset")
    else if (w.lasts === false && w.exhaustAt !== "")
      parts.push(parseMs(w.exhaustAt) <= nowMs ? "spent" : "runs out ~" + clockText(w.exhaustAt))
    parts.push("auto-switch at " + Math.round(shownThreshold) + "%")
    return parts.join(" · ")
  }

  function accountNote(a) {
    var notes = []
    if (a.activeOn.length > 0 && !everywhere(a.activeOn)) notes.push("active on " + joinNames(a.activeOn) + " only")
    var missing = reachable.map(function(m) { return m.machine }).filter(function(n) { return a.on.indexOf(n) < 0 })
    if (missing.length) notes.push("missing on " + joinNames(missing)
      + (localMachine && missing.indexOf(localMachine.machine) >= 0 ? " (log in here and use Add this machine's login)" : ""))
    if (a.disabledOn.length) notes.push("held out of auto-rotation" + (everywhere(a.disabledOn) ? "" : " on " + joinNames(a.disabledOn)))
    var s = a.usageStatus
    var statusNotes = {
      token_expired: "token expired, cswap retries on its own",
      relogin_required: "needs a fresh login",
      foreign_credential: "credential drift, a switch repairs it",
      no_credentials: "no stored credentials",
      unavailable: "usage unavailable right now",
      api_key: "API key, no subscription limits"
    }
    if (s !== "" && s !== "ok") notes.push(statusNotes[s] || s.replace(/_/g, " "))
    else if (a.fetchedMs > 0 && nowMs - a.fetchedMs > 900000) notes.push("usage from " + formatDuration(nowMs - a.fetchedMs) + " ago")
    return notes.join(" · ")
  }

  // ---------------------------------------------------------------- issues

  // Red banners at the top, most urgent first; `fix` is an optional one-click action.
  function collectIssues() {
    var out = []
    if (pollFailed && machines.length === 0)
      out.push({ text: "Can't run the cswap-bar helper", fix: null })
    for (var i = 0; i < machines.length; i++) {
      var m = machines[i]
      if (m.unreachable || !m.data)
        out.push({ text: "Can't reach " + m.machine + (m.err ? ": " + String(m.err).trim().split("\n").pop() : ""), fix: null })
      else if (m.data.error)
        out.push({ text: String(m.data.error), fix: null })
      else if (!m.data.list)
        out.push({ text: "claude-swap did not answer on " + m.machine + " (cswap list failed)", fix: null })
      else if (m.data.engine !== "active" && m.data.engineEnabled === "enabled")
        out.push({ text: "Auto-switch has " + m.data.engine + " on " + m.machine + ".",
                   fix: { label: "Start", args: ["auto", "on"], title: "Starting auto-switch" + everywhereText + "…" } })
    }
    if (!inSync && primaryActive) {
      var parts = activeByMachine.map(function(a) { return a.machine + " #" + displayNumber(a.email) })
      out.push({ text: "Out of sync: " + parts.join(", ") + ".",
                 fix: { label: "All to #" + displayNumber(primaryActive.email), args: ["switch", primaryActive.email],
                        title: "Bringing every machine to #" + displayNumber(primaryActive.email) + "…" } })
    }
    return out
  }

  // ---------------------------------------------------------------- data

  function refresh() {
    if (stateProc.running) return
    stateProc.command = helperBase.concat(["json"])
    stateProc.running = true
  }

  function applyState(raw) {
    nowMs = Date.now()
    var data = null
    try { data = JSON.parse(raw) } catch (e) { data = null }
    if (!data || !Array.isArray(data.machines)) { pollFailed = true; return }
    pollFailed = false
    var previous = {}
    for (var i = 0; i < machines.length; i++) previous[machines[i].machine] = machines[i]
    machines = data.machines.map(function(m) {
      if (m.data) return { machine: m.machine, host: m.host, data: m.data, unreachable: false, err: "" }
      var prev = previous[m.machine]
      return { machine: m.machine, host: m.host, data: prev ? prev.data : null, unreachable: true, err: m.err || "" }
    })
    var rescue = autoFallbackTarget()
    if (rescue) {
      fallbackNote = ""
      runAction(["fallback", rescue.email],
                "Everything is past the limit; moving to #" + rescue.number + ", which still has a session window…")
    }
    // A written threshold shows as pending until a poll after the write reads it back.
    if (thresholdSettling && !applyTimer.running && !actionProc.running) {
      thresholdSettling = false
      pendingThreshold = -1
    }
  }

  function runAction(args, label, stdinText) {
    if (actionProc.running) return
    armedKey = ""
    actionKind = args[0]
    actionLabel = label
    actionLines = []
    pendingStdin = stdinText || ""
    actionProc.stdinEnabled = pendingStdin !== ""
    actionProc.command = helperBase.concat(args)
    actionProc.running = true
  }

  // One line per machine: cswap's own message, or what went wrong there.
  function finishAction(raw) {
    var data = null
    try { data = JSON.parse(raw) } catch (e) { data = null }
    var lines = []
    if (!data || !Array.isArray(data.machines) || data.machines.length === 0) {
      lines.push({ text: "The helper failed" + (raw ? ": " + String(raw).trim().slice(-200) : ""), bad: true })
    } else {
      data.machines.forEach(function(m) {
        var d = m.data
        var prefix = m.machine + (m.copied ? " (copy)" : "") + ": "
        if (!d) { lines.push({ text: prefix + "not reachable" + (m.err ? ", " + String(m.err).trim().split("\n").pop() : ""), bad: true }); return }
        var r = d.result
        if (r && r.error) { lines.push({ text: prefix + String(r.error.message || r.error.type), bad: true }); return }
        if (d.code !== 0) {
          var why = String(d.err || d.out || "").trim().split("\n").pop()
          lines.push({ text: prefix + (why || "failed (" + d.code + ")"), bad: true })
          return
        }
        var msg = r && r.message ? String(r.message)
          : (r && r.email ? "added " + r.email : String(d.out || "").trim().split("\n").pop())
        var warnings = r && Array.isArray(r.warnings) && r.warnings.length ? " · " + r.warnings.join(" · ") : ""
        lines.push({ text: prefix + (msg || "done") + warnings, bad: false })
      })
    }
    if (actionKind === "threshold") thresholdSettling = true
    if (actionKind === "fallback") {
      var refused = lines.length === 1 && lines[0].bad && lines[0].text.indexOf("cooldown") >= 0
      fallbackNote = refused ? lines[0].text : ""
      if (refused) lines = []
    }
    actionLines = lines
    actionLabel = ""
    pendingStdin = ""
    resultTimer.restart()
    refresh()
  }

  // Two-press guard: the first press arms `key`, the second runs it.
  function armOrRun(key, args, label) {
    if (actionProc.running) return
    if (armedKey !== key) { armedKey = key; armTimer.restart(); return }
    runAction(args, label)
  }

  function requestSwitch(a) {
    if (!a) return
    if (everywhere(a.activeOn)) {
      armedKey = ""
      actionLines = [{ text: "#" + a.number + " is already active" + everywhereText, bad: false }]
      resultTimer.restart()
      return
    }
    armOrRun("switch:" + a.email, ["switch", a.email], (multi ? "Switching every machine to #" : "Switching to #") + a.number + "…")
  }

  function stepThreshold(delta) {
    var base = pendingThreshold >= 0 ? pendingThreshold : Math.round(threshold)
    pendingThreshold = clamp(base + delta, 50, 100)
    thresholdSettling = false
    applyTimer.restart()
  }

  function toggleAuto() {
    if (actionProc.running) return
    runAction(["auto", autoOn ? "off" : "on"], autoOn ? "Stopping auto-switch" + everywhereText + "…" : "Starting auto-switch" + everywhereText + "…")
  }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    armedKey = ""
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: stateProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyState(text) }
  }
  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.finishAction(text) }
    // Setup tokens go in on stdin so they never show up in a process list.
    onStarted: if (root.pendingStdin !== "") {
      write(root.pendingStdin + "\n")
      stdinEnabled = false
    }
  }
  Timer {
    interval: root.opened ? 15000 : 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }
  Timer { id: armTimer; interval: 4000; onTriggered: root.armedKey = "" }
  Timer { id: resultTimer; interval: 15000; onTriggered: root.actionLines = [] }
  // Threshold steps settle for 1.2 s before they are written: each write
  // restarts the auto-switch engine.
  Timer {
    id: applyTimer
    interval: 1200
    onTriggered: {
      if (root.pendingThreshold < 0) return
      if (root.pendingThreshold === Math.round(root.threshold)) { root.pendingThreshold = -1; return }
      if (actionProc.running) { restart(); return }
      root.runAction(["threshold", String(root.pendingThreshold)], "Setting the threshold to " + root.pendingThreshold + "%" + root.everywhereText + "…")
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    active: root.alarming
    // The bar's shared tooltip auto-detects rich text and has no plain-text
    // switch, while these lines carry emails, machine names and error text
    // from claude-swap and ssh. plainTooltip() keeps that from ever parsing
    // as markup.
    tooltipText: {
      if (!root.primaryActive)
        return root.plainTooltip(root.issues.length ? root.issues[0].text : (root.noAccounts ? "claude-swap has no accounts yet" : "Loading…"))
      var lines = root.activeByMachine.map(function(a) { return a.machine + ": #" + root.displayNumber(a.email) + " " + a.email })
      if (root.issues.length) lines.push(root.issues[0].text)
      return root.plainTooltip(lines.join("\n"))
    }
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(1100))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Claude accounts"
            meta: root.noAccounts ? "No accounts yet, add one below"
              : !root.primaryActive ? (root.issues.length ? "Needs attention" : "Loading…")
              : !root.inSync ? "Machines on different accounts"
              : "#" + root.displayNumber(root.primaryActive.email) + " active"
                + (root.multi ? " on " + root.joinNames(root.activeByMachine.map(function(a) { return a.machine })) : "")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: root.alarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- issues ----------
          Repeater {
            model: root.issues
            BorderSurface {
              required property var modelData
              width: column.width
              implicitHeight: Math.max(issueText.implicitHeight, fixButton.visible ? fixButton.implicitHeight : 0) + Style.spacing.xl * 2
              color: root.alpha(root.urgent, 0.10)
              borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
              radius: Style.cornerRadius

              Text {
                id: issueText
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: fixButton.visible ? fixButton.left : parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                text: modelData.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button {
                id: fixButton
                visible: !!modelData.fix
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.fix ? modelData.fix.label : ""
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                opacity: actionProc.running ? 0.45 : 1
                onClicked: if (modelData.fix) root.runAction(modelData.fix.args, modelData.fix.title)
              }
            }
          }

          // ---------- accounts ----------
          Column {
            id: accountsSection
            visible: root.accounts.length > 0
            width: parent.width
            spacing: Style.space(14)

            Item {
              width: parent.width
              implicitHeight: accountsHeader.implicitHeight
              PanelSectionHeader {
                id: accountsHeader
                anchors.left: parent.left
                text: "ACCOUNTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              // Legend for the two ticks on every meter.
              Row {
                anchors.right: parent.right
                anchors.verticalCenter: accountsHeader.verticalCenter
                spacing: Style.space(10)
                Row {
                  spacing: Style.space(4)
                  Rectangle { width: Style.space(2); height: Style.space(10); color: root.alpha(root.foreground, 0.6); anchors.verticalCenter: parent.verticalCenter }
                  Text { textFormat: Text.PlainText; text: "even pace"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                }
                Row {
                  spacing: Style.space(4)
                  Rectangle { width: Style.space(2); height: Style.space(10); color: root.urgent; anchors.verticalCenter: parent.verticalCenter }
                  Text { textFormat: Text.PlainText; text: "switch at " + Math.round(root.shownThreshold) + "%"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                }
              }
            }

            Repeater {
              model: root.accounts
              AccountCard {
                required property var modelData
                width: accountsSection.width
                account: modelData
              }
            }
          }

          // ---------- what just happened ----------
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.actionLabel !== "" || root.armedKey !== "" || root.actionLines.length > 0

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.actionLabel !== "" ? root.actionLabel
                : (root.armedKey !== "" ? "Click again to confirm" : "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.actionLabel === "" && root.armedKey === "" ? root.actionLines : []
              Text {
                required property var modelData
                textFormat: Text.PlainText
                width: parent.width
                text: modelData.text
                color: modelData.bad ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- auto-switch ----------
          Column {
            id: engineSection
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "AUTO-SWITCH"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // On/off for claude-swap-auto.service on every machine; turning it on
            // installs the unit from ./systemd where it is missing.
            Item {
              width: parent.width
              implicitHeight: Math.max(autoLabel.implicitHeight, autoToggle.implicitHeight)
              Column {
                id: autoLabel
                anchors.left: parent.left
                anchors.right: autoToggle.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  textFormat: Text.PlainText
                  text: "Rotate automatically"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.autoOn ? (root.multi ? "on every machine" : "on")
                    : (root.autoMixed ? "only on some machines" : (root.autoInstalled ? (root.multi ? "off everywhere" : "off") : "off (turning it on installs a user service)"))
                  color: root.autoMixed ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              ToggleSwitch {
                id: autoToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.autoOn
                busy: actionProc.running && root.actionKind === "auto"
                foreground: root.foreground
                onToggled: root.toggleAuto()
              }
            }

            // Threshold stepper, written 1.2 s after the last click.
            Item {
              width: parent.width
              implicitHeight: Math.max(thresholdLabel.implicitHeight, stepper.implicitHeight)
              Column {
                id: thresholdLabel
                anchors.left: parent.left
                anchors.right: stepper.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  textFormat: Text.PlainText
                  text: "Switch away at"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.pendingThreshold >= 0 ? "saving…" : "the active account's fullest limit"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Row {
                id: stepper
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                Button {
                  text: "−"
                  fontSize: Style.font.body
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.stepThreshold(-1)
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(44)
                  horizontalAlignment: Text.AlignHCenter
                  text: Math.round(root.shownThreshold) + "%"
                  color: root.pendingThreshold >= 0 ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Button {
                  text: "+"
                  fontSize: Style.font.body
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.stepThreshold(1)
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- manage (the TUI's add / disable / remove menus) ----------
          Column {
            id: manageSection
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(manageHeader.implicitHeight, manageToggle.implicitHeight)
              PanelSectionHeader {
                id: manageHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "MANAGE ACCOUNTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Button {
                id: manageToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.manageOpen ? "Hide" : "Show"
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.manageOpen = !root.manageOpen
              }
            }

            Column {
              visible: root.manageOpen || root.noAccounts
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.accounts
                Item {
                  id: manageRow
                  required property var modelData
                  readonly property bool disabledHere: modelData.disabledOn.length > 0
                  readonly property var missing: root.reachable.map(function(m) { return m.machine })
                    .filter(function(n) { return modelData.on.indexOf(n) < 0 })
                  readonly property string removeKey: "remove:" + modelData.email
                  width: manageSection.width
                  implicitHeight: Math.max(manageName.implicitHeight, manageButtons.implicitHeight)

                  Text {
                    id: manageName
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.right: manageButtons.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "#" + manageRow.modelData.number + "  " + manageRow.modelData.email
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Row {
                    id: manageButtons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)
                    // Only outward from this machine: nothing is ever imported here.
                    Button {
                      visible: manageRow.missing.length > 0 && !!root.localMachine
                        && manageRow.modelData.on.indexOf(root.localMachine.machine) >= 0
                      text: "Copy to " + manageRow.missing.join(" + ")
                      tooltipText: "Copy this account's stored login from this machine"
                      fontSize: Style.font.caption
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      bordered: true
                      onClicked: root.runAction(["copy", manageRow.modelData.email],
                                                "Copying #" + manageRow.modelData.number + " to " + manageRow.missing.join(" + ") + "…")
                    }
                    Button {
                      text: manageRow.disabledHere ? "Enable" : "Disable"
                      tooltipText: manageRow.disabledHere ? "Return it to auto-rotation" + root.everywhereText : "Hold it out of auto-rotation" + root.everywhereText + " (switching to it by hand still works)"
                      fontSize: Style.font.caption
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      bordered: true
                      onClicked: root.runAction([manageRow.disabledHere ? "enable" : "disable", manageRow.modelData.email],
                                                (manageRow.disabledHere ? "Enabling" : "Disabling") + " #" + manageRow.modelData.number + root.everywhereText + "…")
                    }
                    Button {
                      text: root.armedKey === manageRow.removeKey ? "Really remove" : "Remove"
                      tooltipText: "Remove it from claude-swap" + (root.multi ? " on every machine" : "") + " (asks twice)"
                      fontSize: Style.font.caption
                      foreground: root.urgent
                      fontFamily: root.fontFamily
                      bordered: true
                      onClicked: root.armOrRun(manageRow.removeKey, ["remove", manageRow.modelData.email],
                                               "Removing #" + manageRow.modelData.number + root.everywhereText + "…")
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: !!root.localMachine
                width: parent.width
                topPadding: Style.space(4)
                text: "Add the account Claude Code on this machine is logged in to now. For another account, run /login in Claude Code and add again."
                  + (root.multi ? " Accounts are copied to the other machines; they only ever travel from this machine outward." : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button {
                visible: !!root.localMachine
                text: "Add this machine's login"
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                opacity: actionProc.running ? 0.45 : 1
                onClicked: root.runAction(["add-login"], "Adding this machine's current login…")
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                topPadding: Style.space(4)
                text: "Or paste a token from claude setup-token (or an API key)" + (root.multi ? "; it is added on every machine." : ".")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Row {
                id: tokenRow
                width: parent.width
                spacing: Style.space(6)
                TextField {
                  id: tokenField
                  width: (tokenRow.width - addTokenButton.width - tokenRow.spacing * 2) * 0.6
                  password: true
                  placeholderText: "sk-ant-…"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                TextField {
                  id: tokenEmail
                  width: (tokenRow.width - addTokenButton.width - tokenRow.spacing * 2) * 0.4
                  placeholderText: "email (optional)"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Button {
                  id: addTokenButton
                  text: "Add"
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  opacity: tokenField.text.trim() === "" || actionProc.running ? 0.45 : 1
                  onClicked: {
                    var token = tokenField.text.trim()
                    if (token === "" || actionProc.running) return
                    var email = tokenEmail.text.trim()
                    root.runAction(email ? ["add-token", email] : ["add-token"], "Adding the token" + root.everywhereText + "…", token)
                    tokenField.text = ""
                    tokenEmail.text = ""
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // One account: number + email, an ACTIVE tag or a Switch button, one meter
  // row per limit window, and a note line (partly active, missing, disabled).
  component AccountCard: Column {
    id: card
    property var account: null
    readonly property bool activeEverywhere: account ? account.activeOn.length > 0 && root.everywhere(account.activeOn) : false
    readonly property bool armed: account ? root.armedKey === "switch:" + account.email : false
    readonly property var windows: root.limitsOf(account)
    readonly property string note: account ? root.accountNote(account) : ""

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(nameColumn.implicitHeight, rightSide.implicitHeight)

      Column {
        id: nameColumn
        anchors.left: parent.left
        anchors.right: rightSide.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: card.account ? "#" + card.account.number + "  " + (card.account.alias ? card.account.alias + " · " : "") + card.account.email : ""
          color: root.foreground
          opacity: card.account && card.account.disabledOn.length ? 0.55 : 1
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: card.account && card.account.activeOn.length > 0
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          visible: card.note !== ""
          width: parent.width
          text: card.note
          color: card.account && card.account.activeOn.length > 0 && !card.activeEverywhere ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Item {
        id: rightSide
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: card.activeEverywhere ? activeTag.implicitWidth : switchButton.implicitWidth
        implicitHeight: card.activeEverywhere ? activeTag.implicitHeight : switchButton.implicitHeight
        width: implicitWidth
        height: implicitHeight

        Text {
          id: activeTag
          visible: card.activeEverywhere
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "ACTIVE"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
        }
        Button {
          id: switchButton
          visible: !card.activeEverywhere
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: card.armed ? "󰄬" : "󰓡"
          iconSize: Style.font.body
          text: card.armed ? "Confirm" : "Switch"
          tooltipText: card.account ? "Switch to #" + card.account.number + " " + card.account.email : ""
          horizontalPadding: Style.space(10)
          fontSize: Style.font.caption
          foreground: card.armed ? root.urgent : root.foreground
          fontFamily: root.fontFamily
          bordered: true
          opacity: actionProc.running ? 0.45 : 1
          onClicked: root.requestSwitch(card.account)
        }
      }
    }

    // The limit rows sit closer together than the card's own spacing.
    Column {
      width: card.width
      spacing: 0
      Repeater {
        model: card.windows
        LimitRow {
          required property var modelData
          width: card.width
          window: modelData
        }
      }
    }
  }

  // Compact table row: title · meter with the even-pace and threshold ticks · % · time to reset.
  component LimitRow: Item {
    id: limitRow
    property var window: null
    readonly property real pct: window ? window.pct : -1
    readonly property bool alarming: pct >= root.shownThreshold
    readonly property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight) + Style.space(4)

    Text {
      id: limitLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(58)
      text: limitRow.window ? limitRow.window.title : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Item {
      id: meterBox
      anchors.left: limitLabel.right
      anchors.right: limitValue.left
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: limitRow.thickness

      Rectangle {
        id: meterTrack
        anchors.fill: parent
        radius: height / 2
        color: root.track
      }
      Rectangle {
        anchors.left: meterTrack.left
        anchors.verticalCenter: meterTrack.verticalCenter
        height: meterTrack.height
        radius: meterTrack.radius
        width: meterTrack.width * root.clamp(limitRow.pct / 100, 0, 1)
        color: limitRow.alarming ? root.urgent : root.foreground
        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      }
      // Where an even burn through the window would be right now.
      Rectangle {
        visible: limitRow.window && limitRow.window.expected >= 0
        width: Math.max(1, Math.round(Style.space(2)))
        height: meterTrack.height + Style.space(6)
        radius: width / 2
        anchors.verticalCenter: meterTrack.verticalCenter
        x: meterTrack.width * root.clamp((limitRow.window ? limitRow.window.expected : 0) / 100, 0, 1) - width / 2
        color: root.alpha(root.foreground, 0.6)
      }
      // The auto-switch threshold.
      Rectangle {
        width: Math.max(1, Math.round(Style.space(2)))
        height: meterTrack.height + Style.space(6)
        radius: width / 2
        anchors.verticalCenter: meterTrack.verticalCenter
        x: meterTrack.width * root.clamp(root.shownThreshold / 100, 0, 1) - width / 2
        color: root.urgent
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
    }

    Text {
      id: limitValue
      textFormat: Text.PlainText
      anchors.right: resetValue.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      horizontalAlignment: Text.AlignRight
      text: limitRow.pct >= 0 ? Math.round(limitRow.pct) + "%" : "—"
      color: limitRow.alarming ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      id: resetValue
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
      horizontalAlignment: Text.AlignRight
      text: limitRow.window ? root.untilText(limitRow.window.resetAt) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: limitHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: limitHover.containsMouse
      text: root.limitTooltip(limitRow.window)
      fontFamily: root.fontFamily
    }
  }
}
