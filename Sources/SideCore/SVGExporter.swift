import Foundation
import AppKit

public enum SVGExporter {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    static func n(_ x: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), x) }
    static func color(_ s: String) -> String {
        guard s != "none", s != "transparent" else { return "none" }
        let c = DrawingPalette.color(s).usingColorSpace(.sRGB)!
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
    public static func export(_ board: SketchBoard, width: Double = 800, height: Double = 560) -> String {
        let size = CGSize(width: width, height: height)
        let scale = min(1.6, max(0.7, min(width / 800, height / 560)))
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(n(width))" height="\(n(height))" viewBox="0 0 \(n(width)) \(n(height))">
        <title>\(escape(board.title))</title>
        <rect width="100%" height="100%" fill="#fbf8ee"/>
        <g stroke-linecap="round" stroke-linejoin="round">
        """
        for e in board.elements {
            let r = DrawingRenderer.rect(e, in: size), x = Double(r.origin.x), y = Double(r.origin.y)
            let w = e.w/1000*width, h = e.h/1000*height, stroke = color(e.color), fill = color(e.fill)
            let attrs = "stroke=\"\(stroke)\" stroke-width=\"\(n(e.strokeWidth))\" fill=\"\(fill)\" fill-opacity=\"0.13\""
            switch e.kind {
            case "image":
                if let id=e.imageID,let data=BoardImages.data(id),let meta=BoardImages.metadata(id){
                    s += "\n<a href=\"\(escape(meta.sourceURL))\"><title>\(escape(meta.title+" · "+meta.credit))</title><image x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(max(1,h-17)))\" preserveAspectRatio=\"xMidYMid meet\" href=\"data:image/png;base64,\(data.base64EncodedString())\"/></a>"
                    let limit=max(8,Int(w/4.8)),credit=meta.credit.count>limit ? String(meta.credit.prefix(limit-1))+"…":meta.credit
                    s += "\n<text x=\"\(n(x))\" y=\"\(n(y+h-5))\" font-family=\"sans-serif\" font-size=\"8\" fill=\"#7a7d7a\">\(escape(credit))</text>"
                }
            case "rect", "highlight": s += "\n<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(h))\" rx=\"7\" \(attrs)/>"
            case "ellipse": s += "\n<ellipse cx=\"\(n(x+w/2))\" cy=\"\(n(y+h/2))\" rx=\"\(n(w/2))\" ry=\"\(n(h/2))\" \(attrs)/>"
            case "line", "arrow":
                s += "\n<path d=\"M \(n(x)) \(n(y)) L \(n(x+w)) \(n(y+h))\" stroke=\"\(stroke)\" stroke-width=\"\(n(e.strokeWidth))\" fill=\"none\"/>"
                if e.kind == "arrow" {
                    let a = atan2(h,w), l = max(11,e.strokeWidth*4), bx=x+w, by=y+h
                    s += "\n<path d=\"M \(n(bx-cos(a-0.45)*l)) \(n(by-sin(a-0.45)*l)) L \(n(bx)) \(n(by)) L \(n(bx-cos(a+0.45)*l)) \(n(by-sin(a+0.45)*l))\" stroke=\"\(stroke)\" stroke-width=\"\(n(e.strokeWidth))\" fill=\"none\"/>"
                }
            case "path":
                if !e.points.isEmpty {
                    let d = e.points.enumerated().map { i,p in "\(i == 0 ? "M" : "L") \(n(p.x/1000*width)) \(n(p.y/1000*height))" }.joined(separator:" ")
                    s += "\n<path d=\"\(d)\" stroke=\"\(stroke)\" stroke-width=\"\(n(e.strokeWidth))\" fill=\"none\"/>"
                }
            default: break
            }
            if !e.text.isEmpty {
                let label = e.kind == "rect" || e.kind == "ellipse"
                let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=3
                let font=TextFitter.font(for:e.text,preferredSize:e.fontSize*scale,
                    in:CGSize(width:w-(label ? 12:0),height:h-(label ? 8:0)),style:paragraph)
                let fontSize = font.pointSize
                let lines = wrap(e.text, font:font, width:max(1,w-(label ? 12:0)))
                let lineHeight = font.ascender - font.descender + 3
                var baseline = y + font.ascender + (label ? max(4,(h-Double(lines.count)*lineHeight)/2):0)
                s += "\n<text fill=\"\(stroke)\" stroke=\"none\" font-family=\"Chalkboard SE, Comic Sans MS, sans-serif\" font-size=\"\(n(fontSize))\" text-anchor=\"\(label ? "middle":"start")\">"
                for line in lines where baseline <= y+h+font.descender {
                    s += "<tspan x=\"\(n(label ? x+w/2:x))\" y=\"\(n(baseline))\">\(escape(line))</tspan>"; baseline += lineHeight
                }
                s += "</text>"
            }
        }
        return s + "\n</g>\n</svg>\n"
    }
    static func wrap(_ text:String, font:NSFont, width:Double) -> [String] {
        var result:[String]=[]
        for paragraph in text.components(separatedBy:"\n") {
            var line=""
            for word in paragraph.components(separatedBy:" ") {
                let next=line.isEmpty ? word:line+" "+word
                if !line.isEmpty && (next as NSString).size(withAttributes:[.font:font]).width > width {
                    result.append(line);line=word
                } else { line=next }
            }
            result.append(line)
        }
        return result
    }
}
