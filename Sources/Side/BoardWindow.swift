import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SideCore

@MainActor final class BoardDocument: ObservableObject {
    @Published var board: SketchBoard
    @Published var pen = false
    @Published var progress: Double = 1
    @Published var caption=""
    var onUserEdit:(()->Void)?
    private var undoStack: [[DrawElement]] = []
    var animation: Task<Void,Never>?
    init(_ board:SketchBoard) { self.board=board }
    func update(_ next:SketchBoard, animate:Bool) {
        animation?.cancel(); undoStack.append(board.elements); board=next
        guard animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {progress=1;return}
        progress=0
        animation=Task { [weak self] in
            await self?.reveal(through:next.elements.count,duration:2)
        }
    }
    func reveal(through count:Int,duration:Double) async {
        let start=progress,target=Double(count)/Double(max(1,board.elements.count))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,duration>0 else{progress=target;return}
        let beginning=Date.timeIntervalSinceReferenceDate
        while !Task.isCancelled {
            let t=min(1,(Date.timeIntervalSinceReferenceDate-beginning)/duration)
            progress=start+(target-start)*t
            if t>=1{return}
            do{try await Task.sleep(for:.milliseconds(16))}catch{return}
        }
    }
    func append(_ element:DrawElement) {onUserEdit?();undoStack.append(board.elements);board.elements.append(element)}
    func undo() {onUserEdit?();if let old=undoStack.popLast(){animation?.cancel();progress=1;board.elements=old}}
    func export() {
        let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"svg")!]
        panel.nameFieldStringValue=board.title.replacingOccurrences(of:"/",with:"-")+".svg"
        panel.canCreateDirectories=true
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try SVGExporter.export(board).write(to:url,atomically:true,encoding:.utf8)}
        catch {NSAlert(error:error).runModal()}
    }
}

struct BoardRoot:View {
    @ObservedObject var document:BoardDocument
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"pencil.and.scribble").foregroundStyle(Color(red:0.58,green:0.49,blue:0.27))
                Text(document.board.title).font(.system(size:14,weight:.medium)).lineLimit(1)
                Spacer()
                Button {document.pen.toggle()} label:{Image(systemName:document.pen ? "pencil.tip.crop.circle.fill":"pencil.tip.crop.circle")}
                    .help("Draw on this board").accessibilityLabel("Draw with pen")
                    .tint(document.pen ? .blue:.primary)
                Button {document.undo()} label:{Image(systemName:"arrow.uturn.backward")}.help("Undo last change").accessibilityLabel("Undo drawing")
                Button("Save SVG",systemImage:"square.and.arrow.up") {document.export()}.help("Export this board as SVG")
            }.buttonStyle(.borderless).padding(.horizontal,20).padding(.vertical,13)
            Rectangle().fill(.black.opacity(0.07)).frame(height:1)
            BoardCanvas(document:document)
            HStack {
                Text(document.pen ? "Pen is on. Drag to draw.":document.caption.isEmpty ? "Ask Side to change or explain anything here.":document.caption).lineLimit(2)
                Spacer();Text("VECTOR BOARD").tracking(1.6).font(.system(size:9,weight:.semibold))
            }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,20).padding(.vertical,9)
        }
        .foregroundStyle(Color(red:0.2,green:0.22,blue:0.22))
        .background(Color(nsColor:DrawingPalette.paper))
        .frame(minWidth:480,minHeight:360)
    }
}

struct BoardCanvas:NSViewRepresentable {
    @ObservedObject var document:BoardDocument
    func makeNSView(context:Context)->SketchCanvasView {let view=SketchCanvasView();view.document=document;return view}
    func updateNSView(_ view:SketchCanvasView,context:Context) {
        view.document=document;view.elements=document.board.elements;view.progress=document.progress
        view.pen=document.pen;view.needsDisplay=true
    }
}

final class SketchCanvasView:NSView {
    var elements:[DrawElement]=[]
    var progress:Double=1
    var pen=false
    weak var document:BoardDocument?
    private var points:[DrawPoint]=[]
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        DrawingPalette.paper.setFill();bounds.fill()
        NSColor.black.withAlphaComponent(0.065).setFill()
        for x in stride(from:CGFloat(22),to:bounds.width,by:24) {
            for y in stride(from:CGFloat(20),to:bounds.height,by:24) {
                NSBezierPath(ovalIn:CGRect(x:x,y:y,width:1,height:1)).fill()
            }
        }
        DrawingRenderer.draw(elements,in:bounds.size,progress:progress)
        if progress>0,progress<1,let tip=PencilPath.tip(elements:elements,progress:progress,in:bounds.size) {
            let pencil=NSBezierPath();pencil.move(to:CGPoint(x:tip.x+2,y:tip.y-3));pencil.line(to:CGPoint(x:tip.x+10,y:tip.y-20))
            pencil.lineWidth=5;pencil.lineCapStyle = .round
            DrawingPalette.color("yellow").setStroke();pencil.stroke()
            DrawingPalette.color("ink").setFill();NSBezierPath(ovalIn:CGRect(x:tip.x-1.7,y:tip.y-1.7,width:3.4,height:3.4)).fill()
        }
        if !points.isEmpty {DrawingRenderer.draw(DrawElement("path",x:0,y:0,color:"blue",points:points),in:bounds.size,overlay:false)}
    }
    private func normalized(_ event:NSEvent)->DrawPoint {
        let p=convert(event.locationInWindow,from:nil)
        return DrawPoint(min(1000,max(0,p.x/bounds.width*1000)),min(1000,max(0,p.y/bounds.height*1000)))
    }
    override func mouseDown(with event:NSEvent) {guard pen else{return};document?.onUserEdit?();points=[normalized(event)];needsDisplay=true}
    override func mouseDragged(with event:NSEvent) {
        guard pen else{return}
        if points.count>=580{points=points.enumerated().filter{$0.offset%2==0}.map(\.element)}
        points.append(normalized(event));needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        guard pen,!points.isEmpty else{return};points.append(normalized(event))
        document?.append(DrawElement("path",x:0,y:0,color:"blue",points:points));points=[];needsDisplay=true
    }
    override func resetCursorRects() {if pen {addCursorRect(bounds,cursor:.crosshair)}}
}

@MainActor final class BoardWindowController:NSWindowController,NSWindowDelegate {
    let boardDocument:BoardDocument
    var onClose:(()->Void)?
    init(board:SketchBoard,screen:NSScreen,offset:Int) {
        boardDocument=BoardDocument(SketchBoard(id:board.id,title:board.title,elements:[]))
        let visible=screen.visibleFrame
        let width=min(840,visible.width-90),height=min(650,visible.height-100)
        let x=visible.minX+(visible.width-width)/2+CGFloat(offset*35)
        let y=visible.minY+(visible.height-height)/2-CGFloat(offset*25)
        let window=NSPanel(contentRect:NSRect(x:x,y:y,width:width,height:height),
            styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Side · \(board.title)";window.titlebarAppearsTransparent=true
        window.titleVisibility = .hidden;window.appearance=NSAppearance(named:.aqua)
        window.backgroundColor=DrawingPalette.paper;window.isReleasedWhenClosed=false
        window.level = .floating;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        window.hidesOnDeactivate=false
        window.contentView=NSHostingView(rootView:BoardRoot(document:boardDocument))
        window.minSize=NSSize(width:500,height:400)
        super.init(window:window)
        window.delegate=self
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func present(_ board:SketchBoard,animate:Bool=true) {
        boardDocument.update(board,animate:animate);window?.title="Side · \(board.title)"
        showWindow(nil);window?.orderFrontRegardless()
    }
    func windowWillClose(_ notification:Notification){
        boardDocument.animation?.cancel();boardDocument.progress=1
        DispatchQueue.main.async{[weak self] in self?.onClose?()}
    }
}
