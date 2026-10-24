import AppKit
import ScreenCaptureKit
import SideCore

struct ScreenSnapshot {
    let dataURL:String
    let displayID:CGDirectDisplayID
    let width:Int
    let height:Int
}

@MainActor final class ScreenCapture {
    static var permitted:Bool {CGPreflightScreenCaptureAccess()}
    static var desktopAvailable:Bool {
        let state=CGSessionCopyCurrentDictionary() as? [String:Any] ?? [:]
        return (state["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true
    }
    static func displayID(_ screen:NSScreen)->CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    static func screen(atPointer:Bool=false)->NSScreen {
        if atPointer,let s=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) {return s}
        return NSScreen.main ?? NSScreen.screens[0]
    }
    func capture(displayID:CGDirectDisplayID,excluding:Set<CGWindowID>) async throws -> ScreenSnapshot {
        guard Self.permitted else {throw SideAPIError("Enable Screen Recording in Settings to let Side see your screen. You can still draw from a typed or spoken question.")}
        guard Self.desktopAvailable else{throw SideAPIError("Unlock your Mac so Side can see the desktop. You can turn Screen off to draw from a question instead.")}
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        guard let display=content.displays.first(where:{$0.displayID==displayID}) else {throw SideAPIError("That display was disconnected. Try again on the current screen.")}
        let windows=content.windows.filter{excluding.contains($0.windowID)}
        let filter=SCContentFilter(display:display,excludingWindows:windows)
        let config=SCStreamConfiguration()
        let ratio=min(1,1600.0/Double(display.width))
        config.width=Int(Double(display.width)*ratio);config.height=Int(Double(display.height)*ratio)
        config.showsCursor=true;config.captureResolution = .best
        let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        try Task.checkCancellation()
        let bitmap=NSBitmapImageRep(cgImage:image)
        guard let jpeg=bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.8]) else {throw SideAPIError("Could not encode the screenshot.")}
        return ScreenSnapshot(dataURL:"data:image/jpeg;base64,"+jpeg.base64EncodedString(),displayID:displayID,width:image.width,height:image.height)
    }
}

final class OverlayCanvas:NSView {
    var elements:[DrawElement]=[] {didSet{needsDisplay=true}}
    var progress:Double=1 {didSet{needsDisplay=true}}
    override var isFlipped:Bool {true}
    override var isOpaque:Bool {false}
    override func draw(_ dirtyRect:NSRect) {
        NSColor.clear.setFill();bounds.fill(using:.copy)
        DrawingRenderer.draw(elements,in:bounds.size,overlay:true,progress:progress)
    }
}

@MainActor final class OverlayController {
    var window:NSPanel?
    let canvas=OverlayCanvas()
    private(set) var elements:[DrawElement]=[]
    private var displayID:CGDirectDisplayID?
    private var sceneBase=0
    var hidden=false {didSet{window?.alphaValue=hidden ? 0:1}}
    func apply(_ scene:DrawScene,screen:NSScreen,initiallyHidden:Bool=false) {
        let id=ScreenCapture.displayID(screen)
        if displayID != id {elements=[];window?.orderOut(nil);window=nil;displayID=id}
        if scene.clearOverlay {elements=[]}
        sceneBase=elements.count
        elements.append(contentsOf:scene.overlay)
        if window == nil {
            let panel=NSPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
            panel.ignoresMouseEvents=true;panel.level=NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1)
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
            panel.contentView=canvas;panel.isReleasedWhenClosed=false;window=panel
        }
        window?.setFrame(screen.frame,display:true);canvas.elements=elements
        canvas.progress=initiallyHidden ? Double(sceneBase)/Double(max(1,elements.count)):1
        window?.alphaValue=hidden ? 0:1
        if elements.isEmpty {window?.orderOut(nil)} else {window?.orderFrontRegardless()}
    }
    func reveal(through count:Int,duration:Double) async {
        let start=canvas.progress,target=Double(sceneBase+count)/Double(max(1,elements.count))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,duration>0 else{canvas.progress=target;return}
        let beginning=Date.timeIntervalSinceReferenceDate
        while !Task.isCancelled {
            let t=min(1,(Date.timeIntervalSinceReferenceDate-beginning)/duration)
            canvas.progress=start+(target-start)*t
            if t>=1{return}
            do{try await Task.sleep(for:.milliseconds(16))}catch{return}
        }
    }
    func finishReveal(){canvas.progress=1}
    func clear() {elements=[];canvas.elements=[];window?.orderOut(nil)}
}
