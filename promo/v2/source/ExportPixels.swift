import Foundation
import Darwin
enum CompanionActivity { case idle, thinking, working, success, attention, stopped }

/// Request states, idle gestures and the settled history mark share one pixel stage.
enum EchoAction: CaseIterable {
    case idle, received, thinking, replying, executing, success, attention, stopped
    case blink, wink, curious, happy
    case history
    init(activity: CompanionActivity, executing: Bool) {
        switch activity {
        case .idle: self = .idle
        case .thinking: self = .thinking
        case .working: self = executing ? .executing : .replying
        case .success: self = .success
        case .attention: self = .attention
        case .stopped: self = .stopped
        }
    }
    var active: Bool { self == .thinking || self == .replying || self == .executing }
    var isBlinkGesture: Bool { self == .blink || self == .wink }
    var label: String {
        switch self {
        case .idle, .blink, .wink, .curious, .happy: return "Echo"
        case .received: return "Echo 已收到任务"
        case .thinking: return "Echo 正在思考"
        case .replying: return "Echo 正在回答"
        case .executing: return "Echo 正在执行命令"
        case .success: return "Echo 已完成"
        case .attention: return "Echo 需要你留意"
        case .stopped: return "Echo 已停下"
        case .history: return "历史 AI 回答"
        }
    }
}

struct EchoPixel {
    var id: Int
    var x: Double
    var y: Double
    var tone: Int
    var opacity: Double
    var darkInk: SIMD3<Double>
    var lightInk: SIMD3<Double>
    init(id: Int, x: Double, y: Double, tone: Int, opacity: Double = 1) {
        self.id = id; self.x = x; self.y = y; self.tone = tone; self.opacity = opacity
        darkInk = Self.ink(tone, light: false); lightInk = Self.ink(tone, light: true)
    }
    private static func ink(_ tone: Int, light: Bool) -> SIMD3<Double> {
        let hex = [0, 0xF4EFDF, light ? 0xAB9E87 : 0xC7BDA8, 0x252A2B, 0xFFFBEF, 0x495250, light ? 0x26795D : 0xA8E7C6, 0xE7A569][tone]
        return SIMD3(Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)) / 255
    }
}

/// A deliberately coarse 14 × 14 stage. Pixel IDs survive changes of expression.
enum EchoPixels {
    static let dimension = 14
    /// The history mark shares the bear's square size and green accent palette.
    private static let historyGlyph: [(x: Int, y: Int)] = [(3, 6), (4, 7), (5, 8), (6, 9), (7, 8), (8, 7), (9, 6), (10, 5), (11, 4)]
    static func frame(action: EchoAction, time: Double, reducedMotion: Bool = false) -> [EchoPixel] {
        let t = reducedMotion ? 0 : max(0, time)
        var grid = Array(repeating: Array(repeating: 0, count: dimension), count: dimension)
        func fill(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>, _ tone: Int) {
            for y in ys { for x in xs { grid[y][x] = tone } }
        }
        fill(2...3, 2...3, 1); fill(10...11, 2...3, 1)
        fill(3...10, 3...9, 2); fill(2...11, 4...8, 2)
        fill(3...10, 4...8, 1); fill(4...9, 3...9, 1)
        if action == .success || action == .happy {
            for x in [4, 9] { grid[5][x] = 3; grid[6][x-1] = 3; grid[6][x+1] = 3 }
        } else if action == .received {
            // Alert, lifted eyes; a small spark acknowledges the new request.
            fill(4...4, 5...6, 3); fill(9...9, 5...6, 3)
        } else if action == .stopped || action == .blink {
            fill(4...5, 6...6, 3); fill(8...9, 6...6, 3)
        } else if action == .wink {
            fill(4...5, 6...6, 3); grid[6][9] = 3
        } else {
            let glance = action == .curious ? 1 : 0
            grid[6][4 + glance] = 3; grid[6][9 + glance] = 3
        }
        let noseY = action == .success ? 8 : 7
        fill(6...7, noseY...noseY, 3)
        if action == .attention { grid[5][4] = 3 }
        var pixels: [EchoPixel] = []
        for y in 0..<dimension { for x in 0..<dimension where grid[y][x] != 0 {
            var p = EchoPixel(id: y * dimension + x, x: Double(x), y: Double(y) + 1, tone: grid[y][x])
            if action == .history {
                let index = pixels.count, target = historyGlyph[pixels.count % historyGlyph.count]
                // Keep the bear's particle IDs: squares travel to the mark, while
                // surplus squares merge into the same destinations and fade away.
                p = EchoPixel(id: p.id, x: Double(target.x), y: Double(target.y), tone: 6,
                              opacity: index < historyGlyph.count ? 1 : 0)
            } else if action == .thinking {
                let index = pixels.count
                let outer = index < 28
                let ringIndex = outer ? index : index - 28
                let count = outer ? 28 : 18
                let angle = Double(ringIndex) / Double(count) * 2 * .pi + t * (outer ? 1.8 : -2.4)
                let radius = outer ? 5.2 : 3.1
                p = EchoPixel(id: p.id, x: 6.5 + cos(angle) * radius, y: 6.5 + sin(angle) * radius,
                              tone: outer ? 1 : 6, opacity: index < 46 ? 0.22 + 0.78 * Double(ringIndex + 1) / Double(count) : 0)
                // Hidden surplus squares gather in the center until the bear reforms.
                if index >= 46 { p.x = 6.5; p.y = 6.5 }
            } else if action == .replying && !reducedMotion {
                p.y += sin(t * 3.2 + Double(x) * 0.24) * 0.16
            } else if action == .executing && !reducedMotion {
                p.y += sin(t * 5) * 0.12
            } else if action == .success && !reducedMotion {
                p.y -= max(0, sin(min(t, 0.8) / 0.8 * .pi)) * 0.8
            }
            pixels.append(p)
        } }
        func dot(_ x: Double, _ y: Double, _ tone: Int, _ opacity: Double = 1) {
            pixels.append(EchoPixel(id: dimension * dimension + Int(y) * dimension + Int(x), x: x, y: y, tone: tone, opacity: opacity))
        }
        switch action {
        case .received:
            for (x, y) in [(11, 1), (12, 0), (13, 1), (12, 2)] { dot(Double(x), Double(y), 7) }
        case .replying:
            for i in 0..<3 { dot(6 + Double(i) * 2, 13, 6, reducedMotion ? 0.8 : 0.25 + 0.75 * (sin(t * 7 - Double(i)) + 1) / 2) }
        case .executing:
            for (i, point) in [(11,0),(12,1),(11,2),(13,3)].enumerated() {
                dot(Double(point.0), Double(point.1), 6, reducedMotion ? 1 : 0.45 + 0.55 * (sin(t * 6 - Double(i)) + 1) / 2)
            }
        case .success:
            for (x,y) in [(10,1),(11,2),(12,1),(13,0)] { dot(Double(x), Double(y), 6) }
        case .attention:
            for y in [1,2,4] { dot(13, Double(y), 7) }
        case .stopped:
            dot(12,0,2); dot(13,0,2); dot(12,1,2); dot(13,1,2)
        default: break
        }
        return pixels
    }
}

/// Interpolate from the pixels currently on screen, so a fast activity change
/// can interrupt a transition without snapping back to the previous face.
struct EchoPixelMotion {
    static let duration = 0.55
    var action: EchoAction = .idle
    var began = Date()
    var source: [EchoPixel] = []
    func frame(at date: Date, reducedMotion: Bool = false) -> [EchoPixel] {
        let elapsed = max(0, date.timeIntervalSince(began))
        let target = EchoPixels.frame(action: action, time: elapsed, reducedMotion: reducedMotion)
        guard !reducedMotion, !source.isEmpty, elapsed < Self.duration else { return target }
        let from = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        let to = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
        return Set(from.keys).union(to.keys).sorted().map { id in
            var a = from[id] ?? to[id]!, b = to[id] ?? from[id]!
            if from[id] == nil { a.opacity = 0 }
            if to[id] == nil { b.opacity = 0 }
            let delay = Double(id % 14) / 13 * 0.12
            let u = min(1, max(0, (elapsed - delay) / (Self.duration - delay)))
            let p = u * u * (3 - 2 * u)
            let flow = sin(.pi * p) * 0.38
            var result = b
            result.x = a.x + (b.x - a.x) * p + sin(Double(id) * 1.7) * flow
            result.y = a.y + (b.y - a.y) * p + cos(Double(id) * 0.9) * flow
            result.x = min(13, max(0, result.x)); result.y = min(13, max(0, result.y))
            result.opacity = a.opacity + (b.opacity - a.opacity) * p
            result.darkInk = a.darkInk + (b.darkInk - a.darkInk) * p
            result.lightInk = a.lightInk + (b.lightInk - a.lightInk) * p
            return result
        }
    }
    @discardableResult mutating func change(to action: EchoAction, at date: Date, reducedMotion: Bool) -> Bool {
        // Closing and reopening the eyes are discrete frames. A real activity
        // interrupting a blink still flows into its own expression as usual.
        let flows = !reducedMotion && !action.isBlinkGesture && !(self.action.isBlinkGesture && action == .idle)
        source = flows ? frame(at: date) : []
        self.action = action; began = date
        return flows
    }
    static func arriving(at date: Date) -> Self {
        let seeds = EchoPixels.frame(action: .received, time: 0).map { pixel in
            var seed = pixel
            let angle = Double(pixel.id) * 2.399963
            seed.x = 6.5 + cos(angle) * 6.2
            seed.y = 6.5 + sin(angle) * 6.2
            seed.opacity = 0
            return seed
        }
        return Self(action: .received, began: date, source: seeds)
    }
    static func celebrationRemaining(completedAt: Date?, now: Date) -> Double {
        min(5, max(0, 5 - now.timeIntervalSince(completedAt ?? now)))
    }
}

/// Presentation timing only: the request and streaming output never wait on it.
enum EchoArrival {
    static let holdDuration = 1.0
    static func remaining(startedAt: Date?, now: Date, action: EchoAction, reducedMotion: Bool) -> Double {
        guard let startedAt, action.active || action == .success else { return 0 }
        let entrance = reducedMotion ? 0 : EchoPixelMotion.duration
        return max(0, entrance + holdDuration - max(0, now.timeIntervalSince(startedAt)))
    }
}


let start = Date(timeIntervalSince1970: 0)
var motion = EchoPixelMotion(action: .idle, began: start)
let events: [(Double,EchoAction)] = [(0,.idle),(1.1,.blink),(1.25,.idle),(6.9,.received),(8.45,.thinking),(9.1,.replying),(10.2,.success),(11.5,.received),(13.05,.thinking),(16.0,.replying),(18.1,.success),(20.0,.idle),(25.0,.success),(27.0,.idle),(27.65,.received),(28.6,.blink),(28.75,.idle)]
var cursor=1
var frames=[[[Double]]]()
for f in 0..<1800 {
 let t=Double(f)/60, date=start.addingTimeInterval(t)
 while cursor<events.count && t>=events[cursor].0 {
  if events[cursor].0 == 27.65 { motion = EchoPixelMotion.arriving(at: start.addingTimeInterval(27.65)) }
  else { motion.change(to:events[cursor].1,at:start.addingTimeInterval(events[cursor].0),reducedMotion:false) }
  cursor += 1
 }
 frames.append(motion.frame(at:date).map { p in [Double(p.id),p.x,p.y,p.darkInk.x,p.darkInk.y,p.darkInk.z,p.opacity] })
}
try JSONSerialization.data(withJSONObject:frames).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
