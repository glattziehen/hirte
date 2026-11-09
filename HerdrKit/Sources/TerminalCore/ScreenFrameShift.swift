import Foundation

/// A verified row translation: new[y] == old[y + rows] in the overlapping band.
public struct ScreenFrameShift: Equatable, Sendable {
    public let rows: Int
    public let region: Range<Int>
}

extension ScreenCell {
    /// Appearance evidence only: an erased cell and a printed space draw the same blank.
    /// Ink attributes matter on blanks with decoration or inverse; background always matters.
    var shiftKey: ScreenCell {
        guard width != 0, text.isEmpty || text == " " else { return self }
        var cell = self
        cell.text = " "
        if !style.underline, !style.strikethrough, !style.inverse {
            cell.style.foreground = nil
            cell.style.bold = false
            cell.style.italic = false
            cell.style.faint = false
            cell.style.invisible = false
        }
        return cell
    }
}

extension ScreenFrame {
    public func rowLooksEqual(_ y: Int, to other: ScreenFrame, _ otherY: Int) -> Bool {
        lines[y].elementsEqual(other.lines[otherY]) { $0.shiftKey == $1.shiftKey }
    }

    /// Conservative presentation evidence, only shortly after user wheel input. The terminal
    /// remains authoritative; ambiguous redraws and selected/cursor rows must snap to it.
    public func shift(from old: ScreenFrame, wheelSign: Int, wheelAge: TimeInterval) -> ScreenFrameShift? {
        guard wheelSign != 0, wheelAge >= 0, wheelAge <= 0.3,
              cols == old.cols, rows == old.rows, lines.count == old.lines.count,
              lines.count == rows, foreground == old.foreground, background == old.background
        else { return nil }
        let key: ([ScreenCell]) -> Int = { line in
            var hash = Hasher()
            for cell in line { hash.combine(cell.shiftKey) }
            return hash.finalize()
        }
        let before = old.lines.map(key)
        let after = lines.map(key)
        let changed = lines.indices.filter { before[$0] != after[$0] }
        guard changed.count >= 4, let a = changed.first, let b = changed.last else { return nil }
        let limit = min((b - a + 1) / 2, 12)
        guard limit > 0 else { return nil }
        var best: (k: Int, run: Range<Int>)?
        for magnitude in 1...limit {
            let k = wheelSign > 0 ? magnitude : -magnitude
            var start = a
            for y in a...b {
                if !(a...b).contains(y + k) || after[y] != before[y + k] || !rowLooksEqual(y, to: old, y + k) {
                    start = y + 1
                } else if y + 1 - start > (best?.run.count ?? 0) {
                    best = (k, start..<(y + 1))
                }
            }
        }
        guard let best,
              Double(best.run.count) >= max(4, 0.6 * Double(changed.count - abs(best.k))),
              Set(best.run.map { after[$0] }).count >= 3
        else { return nil }
        let region = best.k > 0
            ? best.run.lowerBound..<(best.run.upperBound + best.k)
            : (best.run.lowerBound + best.k)..<best.run.upperBound
        for frame in [old, self] {
            if let cursor = frame.cursor, region.contains(cursor.y) { return nil }
            if region.contains(where: { frame.selection.indices.contains($0) && frame.selection[$0] != nil }) { return nil }
        }
        return ScreenFrameShift(rows: best.k, region: region)
    }
}
