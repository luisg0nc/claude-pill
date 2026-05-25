import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

StyledPopup {
    id: root

    function fmtPct(p) {
        if (p < 0) return "—";
        return `${Math.round(p)}%`;
    }

    function fmtRelativeTime(ms) {
        if (!ms || ms <= 0) return "";
        const diff = ms - Date.now();
        if (diff <= 0) return "expired";
        const totalMin = Math.floor(diff / 60000);
        if (totalMin < 60) return `${totalMin}m`;
        const h = Math.floor(totalMin / 60);
        const m = totalMin % 60;
        if (h < 24) return m > 0 ? `${h}h ${m}m` : `${h}h`;
        const d = Math.floor(h / 24);
        return `${d}d ${h % 24}h`;
    }

    function fmtIsoRelative(iso) {
        if (!iso) return "";
        const t = Date.parse(iso);
        if (isNaN(t)) return "";
        return fmtRelativeTime(t);
    }

    function severityColor(pct) {
        if (pct < 0) return Appearance.colors.colOnSurfaceVariant;
        if (pct >= 90) return Appearance.m3colors.m3error;
        if (pct >= 70) return Appearance.m3colors.m3tertiary ?? Appearance.colors.colSecondary;
        return Appearance.colors.colOnSecondaryContainer;
    }

    component LimitRow: ColumnLayout {
        id: limit
        required property string label
        required property real pct
        required property string resetIso
        spacing: 2
        Layout.fillWidth: true

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            StyledText {
                text: limit.label
                color: Appearance.colors.colOnSurfaceVariant
                font.pixelSize: Appearance.font.pixelSize.small
            }
            StyledText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                text: root.fmtPct(limit.pct)
                color: root.severityColor(limit.pct)
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.Medium
            }
        }
        StyledText {
            visible: limit.resetIso.length > 0
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: `resets in ${root.fmtIsoRelative(limit.resetIso)}`
            color: Appearance.colors.colOnSurfaceVariant
            font.pixelSize: Appearance.font.pixelSize.smaller
        }
        StyledProgressBar {
            Layout.fillWidth: true
            value: limit.pct < 0 ? 0 : Math.min(1, limit.pct / 100)
            valueBarWidth: 220
            valueBarHeight: 6
            highlightColor: root.severityColor(limit.pct)
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 8
        implicitWidth: 240

        // Header
        RowLayout {
            spacing: 6
            MaterialSymbol {
                fill: 1
                font.weight: Font.Medium
                text: "auto_awesome"
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colOnSurfaceVariant
            }
            StyledText {
                Layout.fillWidth: true
                text: ClaudeStatus.subscriptionType
                    ? `Claude · ${ClaudeStatus.subscriptionType.charAt(0).toUpperCase() + ClaudeStatus.subscriptionType.slice(1)}`
                    : "Claude"
                font {
                    weight: Font.Medium
                    pixelSize: Appearance.font.pixelSize.normal
                }
                color: Appearance.colors.colOnSurfaceVariant
            }
            StyledText {
                visible: ClaudeStatus.expiresAt > 0
                text: `auth ${root.fmtRelativeTime(ClaudeStatus.expiresAt)}`
                color: Appearance.colors.colOnSurfaceVariant
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }

        // Limits
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            LimitRow {
                label: "Session"
                pct: ClaudeStatus.sessionUsedPct
                resetIso: ClaudeStatus.sessionResetsAt
            }
            LimitRow {
                label: "Week"
                pct: ClaudeStatus.weekUsedPct
                resetIso: ClaudeStatus.weekResetsAt
            }
            LimitRow {
                visible: ClaudeStatus.opusUsedPct >= 0
                label: "Opus week"
                pct: ClaudeStatus.opusUsedPct
                resetIso: ""
            }
        }

        // Error row (only when something's wrong)
        StyledText {
            visible: ClaudeStatus.lastError.length > 0
            Layout.fillWidth: true
            text: ClaudeStatus.lastError
            color: Appearance.m3colors.m3error
            font.pixelSize: Appearance.font.pixelSize.smaller
        }
    }
}
