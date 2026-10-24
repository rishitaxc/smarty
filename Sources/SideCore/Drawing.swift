import Foundation
import AppKit

public struct DrawPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct DrawElement: Codable, Equatable, Sendable {
    public var kind: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var text: String
    public var color: String
    public var fill: String
    public var fontSize: Double
    public var strokeWidth: Double
    public var points: [DrawPoint]
    public var imageID:String?

    public init(_ kind: String, x: Double, y: Double, w: Double = 0, h: Double = 0,
                text: String = "", color: String = "ink", fill: String = "none",
                fontSize: Double = 24, strokeWidth: Double = 2.3, points: [DrawPoint] = [],imageID:String="") {
        self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h
        self.text = text; self.color = color; self.fill = fill
        self.fontSize = fontSize; self.strokeWidth = strokeWidth; self.points = points;self.imageID=imageID
    }
}

public struct SketchBoard: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var elements: [DrawElement]
    public init(id: String = "main", title: String, elements: [DrawElement]) {
        self.id = id; self.title = title; self.elements = elements
    }
}

public struct DrawScene: Codable, Equatable, Sendable {
    public var summary: String
    public var narration: String
    public var clearOverlay: Bool
    public var overlay: [DrawElement]
    public var boards: [SketchBoard]
    public var beats: [DrawBeat]
    public init(summary: String, narration: String = "", clearOverlay: Bool = true,
                overlay: [DrawElement] = [], boards: [SketchBoard] = [], beats: [DrawBeat] = []) {
        self.summary = summary; self.narration = narration; self.clearOverlay = clearOverlay
        self.overlay = overlay; self.boards = boards; self.beats=beats
    }
    enum CodingKeys:String,CodingKey {case summary,narration,clearOverlay,overlay,boards,beats}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        summary=try c.decode(String.self,forKey:.summary);narration=try c.decode(String.self,forKey:.narration)
        clearOverlay=try c.decode(Bool.self,forKey:.clearOverlay);overlay=try c.decode([DrawElement].self,forKey:.overlay)
        boards=try c.decode([SketchBoard].self,forKey:.boards);beats=try c.decodeIfPresent([DrawBeat].self,forKey:.beats) ?? []
    }

    public func validated() throws -> DrawScene {
        guard summary.count <= 12_000, narration.count <= 12_000, boards.count <= 3,
              overlay.count <= 180 else { throw DrawingError.tooLarge }
        var ids = Set<String>()
        for board in boards {
            guard !board.id.isEmpty, ids.insert(board.id).inserted, board.title.count <= 160,
                  board.elements.count <= 220 else { throw DrawingError.invalidBoard }
        }
        for element in overlay + boards.flatMap(\.elements) {
            guard ["text", "rect", "ellipse", "arrow", "line", "path", "highlight","image"].contains(element.kind)
            else { throw DrawingError.unknownShape(element.kind) }
            let numbers = [element.x, element.y, element.w, element.h, element.fontSize, element.strokeWidth]
                + element.points.flatMap { [$0.x, $0.y] }
            guard numbers.allSatisfy(\.isFinite), element.text.count <= 3000,
                  element.points.count <= 600 else { throw DrawingError.invalidCoordinates }
            guard (0...1000).contains(element.x), (0...1000).contains(element.y),
                  (-1000...1000).contains(element.w), (-1000...1000).contains(element.h),
                  (8...64).contains(element.fontSize), (0.5...14).contains(element.strokeWidth),
                  element.points.allSatisfy({ (0...1000).contains($0.x) && (0...1000).contains($0.y) })
            else { throw DrawingError.invalidCoordinates }
            if element.kind == "image"{
                guard let id=element.imageID,BoardImages.metadata(id) != nil,BoardImages.data(id) != nil else{throw SideAPIError("Fetch the reference photo with find_images before drawing its imageID.")}
            }
            if ["text", "rect", "ellipse", "highlight","image"].contains(element.kind) {
                guard element.w > 0, element.h > 0,
                      element.x + element.w <= 1001, element.y + element.h <= 1001
                else { throw DrawingError.invalidCoordinates }
            }
            if ["arrow", "line"].contains(element.kind) {
                guard (0...1000).contains(element.x + element.w),
                      (0...1000).contains(element.y + element.h) else { throw DrawingError.invalidCoordinates }
            }
        }
        guard beats.count<=16 else{throw DrawingError.tooLarge}
        var counts:[String:Int]=[:],overlayCount=0
        for beat in beats {
            guard beat.narration.count<=1200,(overlayCount...overlay.count).contains(beat.overlayThroughElement) else{throw DrawingError.invalidBeats}
            overlayCount=beat.overlayThroughElement
            for reveal in beat.reveals {
                guard let board=boards.first(where:{$0.id==reveal.boardID}),
                      ((counts[board.id] ?? 0)...board.elements.count).contains(reveal.throughElement)
                else{throw DrawingError.invalidBeats}
                counts[board.id]=reveal.throughElement
            }
        }
        if !beats.isEmpty {
            guard overlayCount==overlay.count,boards.allSatisfy({counts[$0.id] == $0.elements.count}) else{throw DrawingError.invalidBeats}
        }
        return self
    }
}

public enum DrawingError: LocalizedError {
    case tooLarge, invalidBoard, invalidCoordinates, invalidBeats, unknownShape(String)
    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The drawing is too large. Ask for a simpler diagram."
        case .invalidBoard: return "The sketch board has an invalid or duplicate identifier."
        case .invalidCoordinates: return "The drawing contains invalid coordinates. Try the request again."
        case .invalidBeats: return "Speech cues must reveal valid board elements in order, and the final cue must reveal every element. throughElement is a count, not a zero-based index."
        case .unknownShape(let shape): return "Unsupported drawing shape: \(shape)."
        }
    }
}

public struct BoardReveal:Codable,Equatable,Sendable {
    public var boardID:String
    public var throughElement:Int
    public init(boardID:String,throughElement:Int){self.boardID=boardID;self.throughElement=throughElement}
}
public struct DrawBeat:Codable,Equatable,Sendable {
    public var narration:String
    public var reveals:[BoardReveal]
    public var overlayThroughElement:Int
    public init(narration:String,reveals:[BoardReveal],overlayThroughElement:Int=0){self.narration=narration;self.reveals=reveals;self.overlayThroughElement=overlayThroughElement}
}

public enum DrawingPalette {
    public static let paper = NSColor(srgbRed: 0.985, green: 0.973, blue: 0.935, alpha: 1)
    public static func color(_ value: String) -> NSColor {
        switch value.lowercased() {
        case "blue": return NSColor(srgbRed: 0.20, green: 0.40, blue: 0.75, alpha: 1)
        case "green": return NSColor(srgbRed: 0.20, green: 0.49, blue: 0.36, alpha: 1)
        case "yellow", "gold": return NSColor(srgbRed: 0.83, green: 0.62, blue: 0.12, alpha: 1)
        case "red": return NSColor(srgbRed: 0.80, green: 0.27, blue: 0.25, alpha: 1)
        case "purple": return NSColor(srgbRed: 0.52, green: 0.37, blue: 0.72, alpha: 1)
        case "white": return .white
        case "gray", "grey": return NSColor(srgbRed: 0.48, green: 0.49, blue: 0.48, alpha: 1)
        case "none", "transparent": return .clear
        case "ink", "black": return NSColor(srgbRed: 0.17, green: 0.20, blue: 0.22, alpha: 1)
        default:
            let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if hex.count == 6, let n = UInt32(hex, radix: 16) {
                return NSColor(srgbRed: CGFloat((n >> 16) & 255) / 255,
                               green: CGFloat((n >> 8) & 255) / 255,
                               blue: CGFloat(n & 255) / 255, alpha: 1)
            }
            return color("ink")
        }
    }
}

/// All scenes use top-left coordinates in a 1000 by 1000 normalized space.
/// Pixel density never enters this mapping. AppKit supplies points; capture supplies pixels.
public enum DrawingRenderer {
    public static func point(_ p: DrawPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x / 1000 * size.width, y: p.y / 1000 * size.height)
    }
    public static func rect(_ e: DrawElement, in size: CGSize) -> CGRect {
        CGRect(x: e.x / 1000 * size.width, y: e.y / 1000 * size.height,
               width: e.w / 1000 * size.width, height: e.h / 1000 * size.height)
    }
    public static func draw(_ elements: [DrawElement], in size: CGSize, overlay: Bool = false, progress: Double = 1) {
        let position=Double(elements.count)*max(0,min(1,progress))
        for (i,e) in elements.enumerated() {
            let fraction=max(0,min(1,position-Double(i)))
            if fraction>0{draw(e,in:size,overlay:overlay,fraction:fraction)}
        }
    }
    public static func draw(_ e: DrawElement, in size: CGSize, overlay: Bool, fraction:Double=1) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let r = rect(e, in: size)
        let stroke = DrawingPalette.color(e.color)
        let fill = DrawingPalette.color(e.fill)
        let lineWidth = CGFloat(e.strokeWidth)
        switch e.kind {
        case "image":
            if let id=e.imageID,let data=BoardImages.data(id),let image=NSImage(data:data),let meta=BoardImages.metadata(id){
                let area=r.insetBy(dx:1,dy:1),height=max(1,area.height-17),ratio=min(area.width/image.size.width,height/image.size.height)
                let destination=CGRect(x:area.midX-image.size.width*ratio/2,y:area.minY+(height-image.size.height*ratio)/2,width:image.size.width*ratio,height:image.size.height*ratio)
                image.draw(in:destination,from:.zero,operation:.sourceOver,fraction:min(1,fraction*2),respectFlipped:true,hints:nil)
                let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail
                (meta.credit as NSString).draw(in:CGRect(x:r.minX,y:r.maxY-14,width:r.width,height:14),withAttributes:[.font:NSFont.systemFont(ofSize:8),.foregroundColor:DrawingPalette.color("gray"),.paragraphStyle:style])
            }
        case "rect", "highlight":
            let q = NSBezierPath(roundedRect: r, xRadius: min(9, r.height / 6), yRadius: min(9, r.height / 6))
            q.lineWidth = e.kind == "highlight" ? max(3, lineWidth) : lineWidth
            fill.withAlphaComponent(e.fill == "none" ? 0 : 0.13*min(1,fraction*2)).setFill(); q.fill()
            if overlay { shadow(stroke.withAlphaComponent(0.22), blur: 3) }
            PencilPath.draw(PencilPath.strokes(for:e,in:size),fraction:fraction,color:stroke,width:q.lineWidth)
            if e.kind == "highlight",fraction>=1 {
                NSShadow().set()
                let inset = q.copy() as! NSBezierPath
                let t = AffineTransform(translationByX: 1.8, byY: 2); inset.transform(using: t)
                stroke.withAlphaComponent(0.32).setStroke(); inset.lineWidth = 1; inset.stroke()
            }
        case "ellipse":
            let q = NSBezierPath(ovalIn: r); q.lineWidth = lineWidth
            fill.withAlphaComponent(e.fill == "none" ? 0 : 0.13*min(1,fraction*2)).setFill(); q.fill()
            PencilPath.draw(PencilPath.strokes(for:e,in:size),fraction:fraction,color:stroke,width:lineWidth)
        case "line", "arrow", "path":
            PencilPath.draw(PencilPath.strokes(for:e,in:size),fraction:fraction,color:stroke,width:lineWidth)
        default: break
        }
        if !e.text.isEmpty {
            let textFraction=e.kind == "text" ? fraction:max(0,min(1,(fraction-0.6)/0.4))
            guard textFraction>0 else{return}
            let isLabel = ["rect", "ellipse"].contains(e.kind)
            let scale = overlay ? 1 : min(1.6, max(0.7, min(size.width / 800, size.height / 560)))
            let style = NSMutableParagraphStyle(); style.alignment = isLabel ? .center : .left
            style.lineBreakMode = .byWordWrapping; style.lineSpacing = 3
            let available = r.insetBy(dx:isLabel ? 6:0,dy:isLabel ? 4:0)
            let font = TextFitter.font(for:e.text,preferredSize:e.fontSize*scale,in:available.size,style:style)
            let ink = overlay && e.kind == "text" ? stroke : DrawingPalette.color(e.color)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: style]
            if overlay {
                let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.8)
                s.shadowBlurRadius = 3; s.shadowOffset = NSSize(width: 0, height: 1); attrs[.shadow] = s
            }
            let text = e.text as NSString
            var box = r.insetBy(dx: isLabel ? 6 : 0, dy: isLabel ? 4 : 0)
            if isLabel {
                let height = text.boundingRect(with: NSSize(width: box.width, height: 5000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs).height
                box.origin.y += max(0, (box.height - height) / 2)
            }
            let visibleText=r.insetBy(dx:0,dy:0)
            NSBezierPath(rect:CGRect(x:visibleText.minX,y:visibleText.minY,width:visibleText.width*textFraction,height:visibleText.height)).addClip()
            text.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        }
    }
    private static func shadow(_ color: NSColor, blur: Double) {
        let s = NSShadow(); s.shadowColor = color; s.shadowBlurRadius = blur; s.set()
    }
    public static func image(elements: [DrawElement], size: CGSize, scale: Double = 2, paper: Bool, progress:Double=1) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: size.height); context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context.cgContext,flipped:true)
        if paper { DrawingPalette.paper.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill() }
        draw(elements, in: size, overlay: !paper,progress:progress)
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}

public enum TextFitter {
    public static func font(for text:String,preferredSize:Double,in size:CGSize,style:NSParagraphStyle?=nil)->NSFont {
        let paragraph=style ?? NSParagraphStyle.default
        var fontSize=preferredSize
        while true {
            let font=NSFont(name:"ChalkboardSE-Regular",size:fontSize) ?? .systemFont(ofSize:fontSize)
            let height=(text as NSString).boundingRect(with:NSSize(width:max(1,size.width),height:100_000),
                options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font,.paragraphStyle:paragraph]).height
            if height<=size.height+0.5 || fontSize<=8{return font}
            fontSize=max(8,fontSize-0.5)
        }
    }
}
