import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

MouseArea {
    id: root

    function severityColor(pct) {
        if (pct < 0) return Appearance.colors.colOnSurfaceVariant;
        if (pct >= 90) return Appearance.m3colors.m3error;
        if (pct >= 70) return Appearance.m3colors.m3tertiary ?? Appearance.colors.colSecondary;
        return Appearance.colors.colOnSecondaryContainer;
    }

    readonly property real sessionPct: ClaudeStatus.sessionUsedPct
    readonly property real weekPct: ClaudeStatus.weekUsedPct
    readonly property bool warn: ClaudeStatus.tokenExpired
    readonly property real maxPct: Math.max(sessionPct, weekPct)

    implicitWidth: row.implicitWidth + 8
    implicitHeight: Appearance.sizes.barHeight
    hoverEnabled: true

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 4

        MaterialSymbol {
            Layout.alignment: Qt.AlignVCenter
            text: root.warn ? "warning" : "auto_awesome"
            iconSize: Appearance.font.pixelSize.large
            fill: 1
            color: root.warn
                ? Appearance.m3colors.m3error
                : root.severityColor(root.maxPct)
        }

        StyledText {
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.weight: Font.Medium
            color: root.warn
                ? Appearance.m3colors.m3error
                : root.severityColor(root.maxPct)
            text: {
                if (root.warn) return "auth";
                if (root.sessionPct < 0 && root.weekPct < 0) return "—";
                const s = root.sessionPct < 0 ? "?" : `${Math.round(root.sessionPct)}%`;
                const w = root.weekPct < 0 ? "?" : `${Math.round(root.weekPct)}%`;
                return `${s} · ${w}`;
            }
        }
    }

    ClaudeStatusPopup {
        id: popup
        hoverTarget: root
    }
}
