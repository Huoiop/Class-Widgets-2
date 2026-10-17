import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import RinUI
import "../editor"


/* “永不自动隐藏的课程”选择器：左侧课表列表，右侧复用学科卡片勾选。
   勾选按课程名称记录、对所有课表生效——同名课程在任意课表中的勾选状态始终一致。 */
Dialog {
    id: root

    title: qsTr("永不自动隐藏这些课程")
    standardButtons: Dialog.Ok | Dialog.Cancel
    modal: true
    width: Math.min(760, (Overlay.overlay ? Overlay.overlay.width : 800) - 80)

    // 课表分组：[{ name, isCurrent, subjects: [{ id, name, ... }, ...] }]
    property var scheduleGroups: []
    // 已勾选的课程名称（全局生效，跨课表共享）
    property var selectedNames: []
    // 已勾选、但不存在于任何课表中的名称（早期手输遗留），单独成组以便取消
    property var orphanNames: []
    property int currentGroupIndex: 0

    readonly property bool locked: Configs.isKeyLocked("interactions.hide.no_hide_subjects")

    // 课表列表与课程网格共用的分组数据
    readonly property var groups: {
        var list = []
        for (var i = 0; i < scheduleGroups.length; ++i) {
            list.push({
                "label": scheduleGroups[i].name,
                "isCurrent": scheduleGroups[i].isCurrent === true,
                "subjects": toArray(scheduleGroups[i].subjects)
            })
        }
        if (orphanNames.length > 0) {
            var orphans = []
            for (var j = 0; j < orphanNames.length; ++j) {
                var name = String(orphanNames[j] || "")
                orphans.push({
                    "id": "__orphan__:" + name,
                    "name": name,
                    "simplifiedName": "",
                    "teacher": "",
                    "icon": "",
                    "color": "",
                    "location": "",
                    "isLocalClassroom": true
                })
            }
            list.push({
                "label": qsTr("不在任何课表中"),
                "isCurrent": false,
                "subjects": orphans
            })
        }
        return list
    }

    readonly property var currentSubjects:
        (currentGroupIndex >= 0 && currentGroupIndex < groups.length)
            ? groups[currentGroupIndex].subjects : []

    onCurrentGroupIndexChanged: {
        if (scheduleList.currentIndex !== currentGroupIndex)
            scheduleList.currentIndex = currentGroupIndex
    }

    onGroupsChanged: {
        if (currentGroupIndex >= groups.length)
            currentGroupIndex = Math.max(0, groups.length - 1)
    }

    // 每次打开时重新读取课表与当前配置，避免课表改动后列表过期。
    // 先恢复 selectedNames，最后才赋值 scheduleGroups——网格委托创建时据此读取勾选态。
    function reloadData() {
        var loadedGroups = AppCentral.scheduleManager.allSchedulesSubjects()
        selectedNames = readSelection()
        orphanNames = collectOrphans(selectedNames, loadedGroups)
        scheduleGroups = loadedGroups
        currentGroupIndex = 0
    }

    onAboutToShow: reloadData()

    onAccepted: Configs.set("interactions.hide.no_hide_subjects", selectedNames)

    // 来自 Python 的 list 在 QML 侧并不是真正的 JS 数组（Array.isArray 为 false），
    // 这种对象直接当模型会导致一个子项都渲染不出来。统一转成真正的 JS 数组。
    function toArray(value) {
        var out = []
        if (!value)
            return out
        if (Array.isArray(value)) {
            for (var i = 0; i < value.length; ++i)
                out.push(value[i])
            return out
        }
        if (typeof value.length === "number") {
            for (var j = 0; j < value.length; ++j)
                out.push(value[j])
        }
        return out
    }

    function isSelected(name) {
        return selectedNames.indexOf(name) >= 0
    }

    function setSelected(name, on) {
        var next = selectedNames.slice()
        var at = next.indexOf(name)
        if (on) {
            if (at >= 0)
                return
            next.push(name)
        } else {
            if (at < 0)
                return
            next.splice(at, 1)
        }
        selectedNames = next

        // 取消勾选孤儿课程后该分组即消失
        if (!on && orphanNames.length > 0) {
            var kept = []
            for (var i = 0; i < orphanNames.length; ++i) {
                if (next.indexOf(orphanNames[i]) >= 0)
                    kept.push(orphanNames[i])
            }
            if (kept.length !== orphanNames.length) {
                orphanNames = kept
                if (currentGroupIndex >= groups.length)
                    currentGroupIndex = Math.max(0, groups.length - 1)
            }
        }
    }

    // SubjectClip 只回传 subjectId，勾选键仍是课程名称。
    function toggleSubject(subjectId) {
        for (var i = 0; i < currentSubjects.length; ++i) {
            if (String(currentSubjects[i].id) === String(subjectId)) {
                var name = currentSubjects[i].name
                setSelected(name, !isSelected(name))
                return
            }
        }
    }

    // Configs.data 中的列表在 QML 侧不一定是真正的 JS 数组，按类数组安全展开
    function readSelection() {
        var stored = Configs.data.interactions.hide.no_hide_subjects
        var out = []
        if (stored && typeof stored.length === "number") {
            for (var i = 0; i < stored.length; ++i) {
                var name = String(stored[i] || "").trim()
                if (name && out.indexOf(name) < 0)
                    out.push(name)
            }
        }
        return out
    }

    function collectOrphans(selection, sourceGroups) {
        var known = []
        for (var i = 0; i < sourceGroups.length; ++i) {
            var subjects = sourceGroups[i].subjects || []
            for (var j = 0; j < subjects.length; ++j) {
                var name = subjects[j] && subjects[j].name
                if (name && known.indexOf(name) < 0)
                    known.push(name)
            }
        }
        var out = []
        for (var k = 0; k < selection.length; ++k) {
            if (known.indexOf(selection[k]) < 0)
                out.push(selection[k])
        }
        return out
    }

    ColumnLayout {
        Layout.preferredWidth: root.width - 48
        spacing: 12

        Text {
            Layout.fillWidth: true
            typography: Typography.Body
            color: Theme.currentTheme.colors.textSecondaryColor
            wrapMode: Text.Wrap
            text: qsTr("这些课程永远不会被自动隐藏（无论是上课、窗口最大化还是全屏触发），选择对所有课表生效。")
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 360
            spacing: 12

            // 左侧课表列表：课表多时可滚动，不挤占课程区域
            ColumnLayout {
                Layout.preferredWidth: 176
                Layout.maximumWidth: 176
                Layout.fillHeight: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    typography: Typography.Caption
                    color: Theme.currentTheme.colors.textSecondaryColor
                    text: qsTr("课表")
                }

                ListView {
                    id: scheduleList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.groups
                    currentIndex: root.currentGroupIndex
                    enabled: !root.locked
                    onItemClicked: function(index) { root.currentGroupIndex = index }

                    delegate: ListViewDelegate {
                        required property var modelData
                        required property int index

                        highlighted: index === root.currentGroupIndex

                        contentItem: RowLayout {
                            spacing: 8

                            Icon {
                                Layout.alignment: Qt.AlignVCenter
                                name: "ic_fluent_calendar_20_regular"
                                size: 18
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                text: modelData.label
                                typography: Typography.Body
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            Text {
                                visible: modelData.isCurrent
                                typography: Typography.Caption
                                color: Theme.currentTheme.colors.textSecondaryColor
                                text: qsTr("当前")
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: Theme.currentTheme.colors.controlBorderColor
            }

            // 右侧课程卡片：复用编辑器里的学科卡片（图标、颜色、教师、地点）
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    typography: Typography.Caption
                    color: Theme.currentTheme.colors.textSecondaryColor
                    text: qsTr("课程")
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    GridView {
                        id: subjectsGrid
                        anchors.fill: parent
                        clip: true
                        cellWidth: Math.max(200, width / Math.max(1, Math.floor(width / 220)))
                        cellHeight: 92

                        model: root.currentSubjects

                        delegate: SubjectClip {
                            required property var modelData

                            width: subjectsGrid.cellWidth - 8
                            height: subjectsGrid.cellHeight - 6
                            enabled: !root.locked
                            selectionMode: true
                            selected: root.isSelected(modelData.name)
                            // 选择器里不允许通过右键菜单删除课程
                            readOnly: true
                            onSelectionToggled: function(subjectId) { root.toggleSubject(subjectId) }
                        }

                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: root.currentSubjects.length === 0
                        typography: Typography.Body
                        color: Theme.currentTheme.colors.textSecondaryColor
                        text: qsTr("该课表中暂无课程")
                    }
                }
            }
        }
    }
}
