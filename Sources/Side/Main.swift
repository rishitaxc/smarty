import AppKit
import SwiftUI
import SideCore
import Combine

final class NotchPanel:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {false}
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    var model:SideModel!
    var notch:NotchPanel!
    var settings:NSWindow?
    var hotKeys:HotKeys!
    var notchHost:NSHostingView<NotchView>?
    var activityObserver:AnyCancellable?
    var keyMonitor:Any?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args=ProcessInfo.processInfo.arguments
        var keyOverride:String?
        if let i=args.firstIndex(of:"--key-file"),args.count>i+1 {keyOverride=try? KeyStore.readDotEnv(at:URL(fileURLWithPath:args[i+1]))}
        model=SideModel(keyOverride:keyOverride)
        if let i=args.firstIndex(of:"--debug-artifacts"),args.count>i+1 {model.debugDirectory=URL(fileURLWithPath:args[i+1])}
        if let i=args.firstIndex(of:"--import-key-from"),args.count>i+1 {
            do {try KeyStore.importDotEnv(at:URL(fileURLWithPath:args[i+1]));model.keyReady=true}
            catch{model.fail(error)}
        }
        setupNotch();setupMenu();hotKeys=HotKeys()
        hotKeys.onPress={ [weak self] id in
            guard let self else{return}
            if id==1 {model.toggleVoice()} else if id==2 {togglePanel()} else {model.stop()}
        }
        activityObserver=model.$activity.sink{[weak self] state in self?.hotKeys.setEscapeEnabled(state != .idle && state != .failed)}
        keyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            guard let self else{return event}
            if event.keyCode==53,(model.conversationMode || model.busy || model.activity == .speaking){model.stop();return nil}
            return event
        }
        model.onSettings={ [weak self] in self?.showSettings() }
        model.onLayout={ [weak self] in self?.layoutNotch() }
        model.controlWindowIDs={ [weak self] in
            guard let self else{return []}
            var ids=Set<CGWindowID>()
            for window in [notch,settings,model.overlay.window].compactMap({$0}) {ids.insert(CGWindowID(window.windowNumber))}
            return ids
        }
        if let i=args.firstIndex(of:"--restore-spatial"),args.count>i+1 {
            do{let scene=try JSONDecoder().decode(SpatialScene.self,from:Data(contentsOf:URL(fileURLWithPath:args[i+1]))).validated();model.applySpatial(scene)}catch{model.fail(error)}
        }
        if let i=args.firstIndex(of:"--restore-boards"),args.count>i+1 {
            do{let scene=try JSONDecoder().decode(DrawScene.self,from:Data(contentsOf:URL(fileURLWithPath:args[i+1]))).validated();model.apply(scene,animate:false)}catch{model.fail(error)}
        }
        if args.contains("--drawing-check") {model.drawingCheck()}
        if args.contains("--3d-check"){model.spatialCheck()}
        if args.contains("--voice-check") || args.contains("--voice-check-conversation") {model.voiceLoopbackCheck(continueConversation:args.contains("--voice-check-conversation"))}
        else if let i=args.firstIndex(of:"--spatial-scene"),args.count>i+1 {
            do{let scene=try JSONDecoder().decode(SpatialScene.self,from:Data(contentsOf:URL(fileURLWithPath:args[i+1]))).validated();model.playSpatial(scene)}catch{model.fail(error)}
        } else if let i=args.firstIndex(of:"--scene"),args.count>i+1 {
            do{let scene=try JSONDecoder().decode(DrawScene.self,from:Data(contentsOf:URL(fileURLWithPath:args[i+1]))).validated();model.playScene(scene)}catch{model.fail(error)}
        } else if let i=args.firstIndex(of:"--ask"),args.count>i+1 {
            model.voiceOutput = !args.contains("--silent");model.includeScreen = !args.contains("--no-screen")
            model.submit(args[i+1])
        } else {model.expanded=true}
        NSApp.activate(ignoringOtherApps:true)
        if model.spatialWindows.isEmpty && model.boards.isEmpty{notch.makeKeyAndOrderFront(nil)}
        if args.contains("--diagnostics") {writeDiagnostics()}
    }
    func setupNotch() {
        notch=NotchPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        notch.isOpaque=false;notch.backgroundColor = .clear;notch.hasShadow=true
        notch.level=NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1)
        notch.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        notch.isReleasedWhenClosed=false;notch.hidesOnDeactivate=false
        layoutNotch();notch.orderFrontRegardless()
    }
    func layoutNotch() {
        let screen=NSScreen.screens.first(where:{$0.safeAreaInsets.top>0}) ?? ScreenCapture.screen()
        let top=max(34,screen.safeAreaInsets.top)
        let camera:CGFloat
        if let left=screen.auxiliaryTopLeftArea,let right=screen.auxiliaryTopRightArea {camera=max(155,right.minX-left.maxX)}else{camera=155}
        let width=model.expanded ? CGFloat(430):camera+105
        if notchHost == nil {
            let hosting=NSHostingView(rootView:NotchView(model:model,topInset:top,cameraWidth:camera))
            hosting.sizingOptions=[]
            notchHost=hosting;notch?.contentView=hosting
        }
        let base:CGFloat=model.response.isEmpty && !model.busy && model.error.isEmpty ? 325:380
        let expandedHeight=base+(model.typing ? 75:0)+(model.note.isEmpty ? 0:30)+(model.sources.isEmpty ? 0:22)
        let height=model.expanded ? expandedHeight:top
        notch?.setFrame(NSRect(x:screen.frame.midX-width/2,y:screen.frame.maxY-height,width:width,height:height),display:true)
    }
    func togglePanel() {
        model.expanded.toggle()
        if model.expanded {NSApp.activate(ignoringOtherApps:true);notch.makeKeyAndOrderFront(nil)}
    }
    func setupMenu() {
        let menu=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu()
        let open=NSMenuItem(title:"Open Side",action:#selector(openSide),keyEquivalent:"d");open.keyEquivalentModifierMask=[.command,.shift];open.target=self
        let talk=NSMenuItem(title:"Talk to Side",action:#selector(talk),keyEquivalent:" ");talk.keyEquivalentModifierMask=[.command,.shift];talk.target=self
        let settings=NSMenuItem(title:"Settings…",action:#selector(showSettings),keyEquivalent:",");settings.target=self
        let quit=NSMenuItem(title:"Quit Side",action:#selector(quit),keyEquivalent:"q");quit.target=self
        for item in [open,talk,settings,quit]{appMenu.addItem(item)}
        appItem.submenu=appMenu;menu.addItem(appItem);NSApp.mainMenu=menu
    }
    @objc func openSide(){model.expanded=true;NSApp.activate(ignoringOtherApps:true);notch.makeKeyAndOrderFront(nil)}
    @objc func talk(){model.toggleVoice()}
    @objc func drawingCheck(){model.drawingCheck()}
    @objc func clearDrawings(){model.clearDrawings()}
    @objc func quit(){NSApp.terminate(nil)}
    @objc func showSettings() {
        if settings == nil {
            let host=NSHostingView(rootView:SettingsView(model:model))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:522,height:680),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="Side Settings";window.contentView=host;window.isReleasedWhenClosed=false
            window.center();settings=window
        }
        NSApp.activate(ignoringOtherApps:true);settings?.makeKeyAndOrderFront(nil)
    }
    func writeDiagnostics() {
        let data:[String:Any]=["screenRecording":ScreenCapture.permitted,"desktopAvailable":ScreenCapture.desktopAvailable,"microphone":VoiceRecorder.permitted,
            "keyConnected":model.keyReady,"model":model.modelName,
            "bundle":Bundle.main.bundleIdentifier ?? "none","runningBundle":NSRunningApplication.current.bundleIdentifier ?? "none",
            "active":NSApp.isActive,"keyWindow":NSApp.keyWindow?.title ?? "none",
            "windows":NSApp.windows.map{["title":$0.title,"number":$0.windowNumber,"visible":$0.isVisible,"key":$0.isKeyWindow,"frame":NSStringFromRect($0.frame)] as [String:Any]},
            "screens":NSScreen.screens.map{["width":$0.frame.width,"height":$0.frame.height,"safeTop":$0.safeAreaInsets.top]}]
        if let json=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted]),let text=String(data:json,encoding:.utf8){print(text);fflush(stdout)}
    }
    func applicationWillTerminate(_ notification:Notification){model?.stop();if let keyMonitor{NSEvent.removeMonitor(keyMonitor)}}
}

@main struct SideMain {
    @MainActor static func main() {
        let app=NSApplication.shared
        if let existing=NSRunningApplication.runningApplications(withBundleIdentifier:"dev.side.notch").first(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {
            existing.activate(options:[]);return
        }
        let delegate=AppDelegate();app.delegate=delegate
        withExtendedLifetime(delegate){app.run()}
    }
}
