pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

// Polls https://api.anthropic.com/api/oauth/usage with the OAuth token from
// ~/.claude/.credentials.json — same endpoint Claude Code's interactive
// /status command hits. Surfaces session-window and weekly utilization,
// merged with local stats from ~/.claude/stats-cache.json for the popup.
//
// Caching: the last successful response is persisted to
// ${XDG_STATE_HOME}/quickshell/user/claude-usage-cache.json with a fetched_at
// timestamp. On startup we ingest the cache first; we only hit the network
// when the cache is older than `fetchInterval`. This prevents every shell
// restart (Ctrl+Super+R) from firing a request, and clamps the polling to a
// single bucket per interval.
Singleton {
    id: root

    readonly property string credentialsPath: FileUtils.trimFileProtocol(`${Directories.home}/.claude/.credentials.json`)
    readonly property string statsPath: FileUtils.trimFileProtocol(`${Directories.home}/.claude/stats-cache.json`)
    readonly property string usageCachePath: FileUtils.trimFileProtocol(`${Directories.state}/user/claude-usage-cache.json`)
    readonly property int fetchIntervalSec: Config.options?.bar?.claudeStatus?.fetchInterval ?? 600
    readonly property int fetchIntervalMs: fetchIntervalSec * 1000
    // Hard floor: regardless of config, never re-poll more often than this.
    readonly property int minIntervalMs: 60 * 1000
    readonly property string endpointOverride: Config.options?.bar?.claudeStatus?.endpointOverride ?? ""
    readonly property string endpoint: endpointOverride.length > 0 ? endpointOverride : "https://api.anthropic.com/api/oauth/usage"

    // ── Credentials (from .credentials.json) ────────────────────────────
    property string subscriptionType: ""
    property string rateLimitTier: ""
    property real expiresAt: 0  // ms epoch
    property bool tokenExpired: false

    // ── Live limits (from /api/oauth/usage) ─────────────────────────────
    property real sessionUsedPct: -1   // five_hour.utilization (0..100). -1 = not yet known
    property real weekUsedPct: -1      // seven_day.utilization
    property real opusUsedPct: -1      // seven_day_opus.utilization (may stay -1 if null)
    property real sonnetUsedPct: -1    // seven_day_sonnet.utilization
    property string sessionResetsAt: ""
    property string weekResetsAt: ""
    property string lastError: ""
    property real lastFetchMs: 0       // when the on-disk cache was written

    // ── Local stats (from stats-cache.json) ─────────────────────────────
    property var modelUsage: ({})       // {model: {inputTokens, outputTokens, cacheReadInputTokens, ...}}
    property var dailyActivity: []      // last 7 days, each {date, messageCount, sessionCount, toolCallCount}
    property int totalSessions: 0
    property string lastComputedDate: ""

    function _readCredentials() {
        try {
            const text = credentialsView.text();
            if (!text) return;
            const j = JSON.parse(text).claudeAiOauth ?? {};
            root.subscriptionType = j.subscriptionType ?? "";
            root.rateLimitTier = j.rateLimitTier ?? "";
            root.expiresAt = Number(j.expiresAt) || 0;
            // tokenExpired flips true on 401 from poll, OR if expiresAt has passed locally
            if (root.expiresAt > 0 && Date.now() > root.expiresAt) {
                root.tokenExpired = true;
            }
        } catch (e) {
            console.warn(`[ClaudeStatus] credentials parse failed: ${e.message}`);
        }
    }

    function _readStats() {
        try {
            const text = statsView.text();
            if (!text) return;
            const j = JSON.parse(text);
            root.modelUsage = j.modelUsage ?? ({});
            root.totalSessions = Number(j.totalSessions) || 0;
            root.lastComputedDate = j.lastComputedDate ?? "";
            const all = Array.isArray(j.dailyActivity) ? j.dailyActivity : [];
            root.dailyActivity = all.slice(-7);
        } catch (e) {
            console.warn(`[ClaudeStatus] stats parse failed: ${e.message}`);
        }
    }

    function _readUsageCache() {
        try {
            const text = usageCacheView.text();
            if (!text) return false;
            const wrapped = JSON.parse(text);
            const fetchedAt = Number(wrapped?.fetched_at) || 0;
            if (!wrapped?.data || !fetchedAt) return false;
            _ingestUsage(wrapped.data, fetchedAt);
            return true;
        } catch (e) {
            console.warn(`[ClaudeStatus] usage cache parse failed: ${e.message}`);
            return false;
        }
    }

    function _writeUsageCache(payload) {
        try {
            usageCacheView.setText(JSON.stringify({
                fetched_at: Date.now(),
                data: payload
            }));
        } catch (e) {
            console.warn(`[ClaudeStatus] usage cache write failed: ${e.message}`);
        }
    }

    function _ingestUsage(payload, fetchedAtMs) {
        function pickPct(o) { return (o && typeof o.utilization === "number") ? o.utilization : -1; }
        function pickReset(o) { return (o && o.resets_at) ? o.resets_at : ""; }
        root.sessionUsedPct = pickPct(payload.five_hour);
        root.weekUsedPct = pickPct(payload.seven_day);
        root.opusUsedPct = pickPct(payload.seven_day_opus);
        root.sonnetUsedPct = pickPct(payload.seven_day_sonnet);
        root.sessionResetsAt = pickReset(payload.five_hour);
        root.weekResetsAt = pickReset(payload.seven_day);
        root.lastError = "";
        root.tokenExpired = false;
        root.lastFetchMs = fetchedAtMs ?? Date.now();
    }

    function _cacheAgeMs() {
        return root.lastFetchMs > 0 ? (Date.now() - root.lastFetchMs) : Infinity;
    }

    function refresh(force) {
        // Hard floor: never poll faster than minIntervalMs, even when forced.
        // Soft floor: skip if cache is fresher than fetchInterval (unless forced).
        const age = _cacheAgeMs();
        if (age < root.minIntervalMs) return;
        if (!force && age < root.fetchIntervalMs) return;

        const token = (function() {
            try {
                const j = JSON.parse(credentialsView.text() ?? "{}");
                return j.claudeAiOauth?.accessToken ?? "";
            } catch (e) {
                return "";
            }
        })();
        if (!token) {
            root.lastError = "no token";
            root.tokenExpired = true;
            return;
        }
        // Token via env so it never lands in argv (which is world-readable in /proc).
        fetcher.environment = { CLAUDE_OAUTH_TOKEN: token };
        fetcher.command = ["bash", "-c",
            'curl -sS --max-time 8 ' +
            '-H "Authorization: Bearer $CLAUDE_OAUTH_TOKEN" ' +
            '-H "Content-Type: application/json" ' +
            '-H "User-Agent: claude-cli/2.1.132 (external, cli)" ' +
            `-w "\\n__HTTP_CODE__:%{http_code}__" '${root.endpoint}'`
        ];
        fetcher.running = true;
    }

    // FileView reads are async — we must wait for both credentials AND the
    // usage cache state before deciding whether to fire the initial network
    // call. Otherwise refresh() runs with an empty token and fails silently.
    property bool _credsLoaded: false
    property bool _cacheChecked: false
    property bool _initialFetchDone: false

    function _maybeInitialFetch() {
        if (_initialFetchDone) return;
        if (!_credsLoaded || !_cacheChecked) return;
        _initialFetchDone = true;
        // refresh(false) skips the network call when the on-disk cache is
        // still within fetchInterval — the whole point of this caching layer.
        refresh(false);
    }

    FileView {
        id: credentialsView
        path: root.credentialsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root._readCredentials();
            root._credsLoaded = true;
            root._maybeInitialFetch();
        }
    }

    FileView {
        id: statsView
        path: root.statsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root._readStats()
    }

    FileView {
        id: usageCacheView
        path: root.usageCachePath
        // No watchChanges — we own this file; reading on demand is enough.
        onLoaded: {
            root._readUsageCache();
            root._cacheChecked = true;
            root._maybeInitialFetch();
        }
        onLoadFailed: error => {
            // FileNotFound is expected on first run; ignore.
            if (error !== FileViewError.FileNotFound) {
                console.warn(`[ClaudeStatus] usage cache load error: ${error}`);
            }
            root._cacheChecked = true;
            root._maybeInitialFetch();
        }
    }

    Process {
        id: fetcher
        command: ["bash", "-c", ":"]
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = text ?? "";
                const m = raw.match(/__HTTP_CODE__:(\d+)__/);
                const code = m ? Number(m[1]) : 0;
                const body = m ? raw.slice(0, m.index) : raw;
                if (code === 401) {
                    root.tokenExpired = true;
                    root.lastError = "401 (re-auth via claude)";
                    return;
                }
                if (code === 429) {
                    // Rate-limited by the API itself. Back off — Timer will
                    // try again next tick, but the floor in refresh() will
                    // prevent any sub-interval retries.
                    root.lastError = "429 rate-limited";
                    return;
                }
                if (code !== 200) {
                    root.lastError = `HTTP ${code || "?"}`;
                    return;
                }
                try {
                    const payload = JSON.parse(body);
                    _ingestUsage(payload, Date.now());
                    _writeUsageCache(payload);
                } catch (e) {
                    root.lastError = `parse: ${e.message}`;
                    console.warn(`[ClaudeStatus] ${root.lastError}`);
                }
            }
        }
    }

    Timer {
        interval: root.fetchIntervalMs
        running: true
        repeat: true
        triggeredOnStart: false  // initial fetch path runs in Component.onCompleted
        onTriggered: root.refresh(false)
    }
}
