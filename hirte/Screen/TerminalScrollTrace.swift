#if DEBUG
import UIKit
import HerdrKit

/// Opt-in, generic demo only. UIKit callbacks and offsets, never physical scanout or SSH RTT.
@MainActor
final class TerminalScrollTrace: NSObject {
    static let shared: TerminalScrollTrace? = {
        guard ProcessInfo.processInfo.environment["HIRTE_SCROLL_TRACE"] == "1",
              UserDefaults.standard.bool(forKey: "hirte.demo") else { return nil }
        return TerminalScrollTrace()
    }()
    private struct Sample {
        var time: Double
        var event: String
        var state: Int
        var touch: CGFloat
        var offset: CGFloat
        var height: CGFloat
    }
    private var samples: [Sample] = []
    private var lastMotion = CACurrentMediaTime()
    private var lastFlush = CACurrentMediaTime()
    private var file: FileHandle?
    private weak var reference: UIScrollView?
    private var link: CADisplayLink?
    private weak var canvas: TerminalCanvasView?
    private weak var sidebar: UIScrollView?

    override init() {
        super.init()
        samples.reserveCapacity(32768)
        let url = URL.documentsDirectory.appendingPathComponent("scroll-trace.csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("time,event,state,touch_y,offset,cell_height\n".utf8))
        file = try? FileHandle(forWritingTo: url)
        try? file?.seekToEnd()
    }

    func attach(_ canvas: TerminalCanvasView) {
        self.canvas = canvas
        if ProcessInfo.processInfo.environment["HIRTE_COAST_REFERENCE"] == "1", reference == nil {
            let scroll = UIScrollView(frame: canvas.bounds)
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scroll.backgroundColor = canvas.backgroundColor
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.bounces = false
            scroll.accessibilityIdentifier = "coast-reference"
            let height: CGFloat = 18
            for row in 0..<1000 {
                let label = UILabel(frame: CGRect(x: 0, y: CGFloat(row) * height, width: 400, height: height))
                label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                label.textColor = UIColor(canvas.screen.foreground)
                label.text = "sample \(row) ready 漢 e\u{301}"
                scroll.addSubview(label)
            }
            scroll.contentSize = CGSize(width: canvas.bounds.width, height: 18000)
            scroll.contentOffset.y = 16000
            scroll.delegate = self
            canvas.addSubview(scroll)
            reference = scroll
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func record(_ event: String, state: Int = 0, touch: CGFloat = 0, offset: CGFloat = 0, height: CGFloat = 0) {
        guard samples.count < 32768 else { return }
        samples.append(Sample(time: CACurrentMediaTime(), event: event, state: state,
                              touch: touch, offset: offset, height: height))
    }

    private func flush() {
        guard !samples.isEmpty else { return }
        var data = Data()
        for sample in samples {
            data.append(contentsOf: String(format: "%.6f,%@,%d,%.3f,%.6f,%.6f\n",
                sample.time, sample.event, sample.state, sample.touch, sample.offset, sample.height).utf8)
        }
        try? file?.write(contentsOf: data)
        samples.removeAll(keepingCapacity: true)
        lastFlush = CACurrentMediaTime()
    }

    func content(_ event: String, frame: ScreenFrame) {
        guard let line = frame.lines.first else { return }
        let text = line.map(\.text).joined()
        guard let number = text.split(separator: " ").dropFirst().first.flatMap({ Double($0) }) else { return }
        record(event, offset: number)
    }

    @objc private func tick() {
        guard let canvas, let window = canvas.window else { return }
        if sidebar?.window == nil {
            func find(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, !scroll.isDescendant(of: canvas),
                   scroll.contentSize.height > scroll.bounds.height, scroll.bounds.width < window.bounds.width / 2 {
                    return scroll
                }
                return view.subviews.lazy.compactMap(find).first
            }
            sidebar = find(window)
        }
        let moving = [canvas.scrollView, sidebar, reference].compactMap { $0 }
            .contains { $0.isDragging || $0.isDecelerating || $0.isTracking }
        let now = CACurrentMediaTime()
        if moving { lastMotion = now }
        if now - lastMotion < 0.5 {
            record("display", state: canvas.scrollView.isDecelerating ? 4 : 0,
                   touch: link?.timestamp ?? 0, offset: canvas.scrollView.contentOffset.y,
                   height: (link?.targetTimestamp ?? 0) - (link?.timestamp ?? 0))
            if let sidebar {
                let pan = sidebar.panGestureRecognizer
                record("sidebar", state: sidebar.isDecelerating ? 4 : pan.state.rawValue,
                       touch: pan.location(in: window).y, offset: sidebar.contentOffset.y)
            }
            if let reference {
                record("reference-display", state: reference.isDecelerating ? 4 : 0,
                       offset: reference.contentOffset.y)
            }
        } else if now - lastFlush > 1 { flush() }
    }
}
extension TerminalScrollTrace: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        record("reference", state: scrollView.isDecelerating ? 4 : 2,
               offset: scrollView.contentOffset.y)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        record("reference-release", state: decelerate ? 4 : 0, offset: scrollView.contentOffset.y)
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        record("reference-stop", offset: scrollView.contentOffset.y)
    }
}
#endif
