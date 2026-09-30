/*
 * 课程表的时间轴映射（纯函数）。
 *
 * 比例轴给不了过短的时段足够的显示高度，所以轴在每个时段边界处切开、给过短的
 * 时段补足长度。补出的长度插在该时段自身区间末尾：下方整体下移而非互相覆盖，
 * 刻度线读同一套分段，因此不会与时段错位。
 *
 * 分段为 { start, end, length, visualStart }（分钟 / 像素），可带 gapBefore。
 * 不能加 .pragma library —— 本项目的 Qt JS 解析器会拒绝该指令并导致整文件加载失败。
 */

// minutes -> y。落在被挖掉的分隔带里的分钟钳到其后一段。
function map(segments, minutes) {
    for (let i = 0; i < segments.length; ++i) {
        const segment = segments[i]
        if (minutes <= segment.start)
            return segment.visualStart
        if (minutes <= segment.end) {
            return segment.visualStart
                + (minutes - segment.start) * segment.length
                    / (segment.end - segment.start)
        }
    }
    const last = segments.length ? segments[segments.length - 1] : null
    return last ? last.visualStart + last.length : 0
}

// 区间当前占的像素长度。
function length(segments, startMinutes, endMinutes) {
    let total = 0
    for (let i = 0; i < segments.length; ++i) {
        const segment = segments[i]
        const from = Math.max(segment.start, startMinutes)
        const to = Math.min(segment.end, endMinutes)
        if (to > from) {
            total += (to - from) * segment.length
                / (segment.end - segment.start)
        }
    }
    return total
}

// 把 deficit 像素加进区间内最后一段，即该时段的末尾。边界都是切点，必然能找到。
function expand(segments, startMinutes, endMinutes, deficit) {
    for (let i = segments.length - 1; i >= 0; --i) {
        const segment = segments[i]
        if (segment.start >= startMinutes && segment.end <= endMinutes) {
            segment.length += deficit
            return
        }
    }
}

// map 的反函数：y -> minutes，用于缩放时保持滚动锚点。
function minuteAt(segments, y) {
    for (let i = 0; i < segments.length; ++i) {
        const segment = segments[i]
        if (y <= segment.visualStart)
            return segment.start
        if (y <= segment.visualStart + segment.length) {
            return segment.start
                + (y - segment.visualStart) * (segment.end - segment.start)
                    / segment.length
        }
    }
    const last = segments.length ? segments[segments.length - 1] : null
    return last ? last.end : 0
}

// 按长度累加出各段 visualStart，返回轴总高。
function layout(segments) {
    let cursor = 0
    for (let i = 0; i < segments.length; ++i) {
        const segment = segments[i]
        cursor += segment.gapBefore || 0
        segment.visualStart = cursor
        cursor += segment.length
    }
    return cursor
}
