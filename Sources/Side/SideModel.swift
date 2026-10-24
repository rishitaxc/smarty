import AppKit
import SwiftUI
import SideCore

enum Activity:String {
    case idle="Ready",listening="Listening",transcribing="Transcribing",thinking="Thinking",drawing="Drawing",speaking="Speaking",failed="Needs attention"
}

@MainActor final class SideModel:ObservableObject {
    @Published var activity:Activity = .idle {didSet{onLayout?()}}
    @Published var draft=""
    @Published var response="" {didSet{onLayout?()}}
    @Published var lastQuestion=""
    @Published var expanded=false {didSet{onLayout?()}}
    @Published var level:Double=0
    @Published var error="" {didSet{onLayout?()}}
    @Published var note="" {didSet{onLayout?()}}
    @Published var typing=false {didSet{onLayout?()}}
    @Published var keyReady=false
    @Published var boardCount=0
    @Published var sources:[(title:String,url:String)]=[]
    @Published var conversationMode=false
    @Published var voiceOutput=UserDefaults.standard.object(forKey:"voiceOutput") as? Bool ?? true {
        didSet {UserDefaults.standard.set(voiceOutput,forKey:"voiceOutput");if !voiceOutput{player.stop();if activity == .speaking {activity = .idle}}}
    }
    @Published var includeScreen=ScreenCapture.permitted
    @Published var webEnabled=true
    @Published var modelName=UserDefaults.standard.string(forKey:"model") ?? "gpt-6.1-sol" {
        didSet{UserDefaults.standard.set(modelName,forKey:"model")}
    }
    var onLayout:(()->Void)?
    var onSettings:(()->Void)?
    var controlWindowIDs:(()->Set<CGWindowID>)?
    let overlay=OverlayController()
    let recorder=VoiceRecorder()
    let player=VoicePlayer()
    let capture=ScreenCapture()
    var boards:[String:BoardWindowController]=[:]
    var spatialWindows:[String:SpatialWindowController]=[:]
    var pendingSpatial:SpatialWindowController?
    var activeSpatialID:String?
    var hasSpatialModel:Bool{activeSpatialID.flatMap{spatialWindows[$0]} != nil}
    var task:Task<Void,Never>?
    var presentation:Task<Void,Never>?
    var latestScene:DrawScene?
    var latestSpatial:SpatialScene?
    var history:[(question:String,answer:String)]=[]
    var currentScreen:NSScreen=ScreenCapture.screen()
    var debugDirectory:URL?
    private let keyOverride:String?
    var busy:Bool {[.listening,.transcribing,.thinking,.drawing].contains(activity)}
    var accent:Color {
        switch activity {
        case .listening:return Color(red:0.87,green:0.68,blue:0.36)
        case .failed:return Color(red:0.95,green:0.5,blue:0.45)
        default:return Color(red:0.74,green:0.79,blue:0.59)
        }
    }
    init(keyOverride:String?=nil) {
        self.keyOverride=keyOverride
        keyReady=keyOverride != nil || KeyStore.load() != nil
        recorder.onLevel={ [weak self] in self?.level=$0 }
        recorder.onAutoStop={ [weak self] in self?.finishRecording() }
        recorder.onDiagnostics={ [weak self] in self?.trace("microphone-meter",$0) }
        recorder.onError={ [weak self] in self?.fail($0) }
        player.onFinished={ [weak self] in
            if self?.activity == .speaking,self?.presentation == nil {self?.activity = .idle;self?.resumeConversation()}
        }
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.overlay.clear();self?.onLayout?() }
        }
        for name in [NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.stop()}}
        }
        DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.stop()}}
    }
    func client() throws ->OpenAIClient {
        guard let key=keyOverride ?? KeyStore.load() else{keyReady=false;throw SideAPIError("Add your OpenAI API key in Settings to talk to Sol.")}
        keyReady=true;return OpenAIClient(key:key,model:modelName)
    }
    func toggleVoice() {
        if activity == .listening {finishRecording();return}
        stop();error="";expanded=true
        conversationMode=true
        currentScreen=ScreenCapture.screen(atPointer:true)
        task=Task { [weak self] in
            guard let self else{return}
            do {
                _=try client();try await recorder.start();try Task.checkCancellation();activity = .listening
            } catch is CancellationError {}
            catch {if !Task.isCancelled{fail(error)}}
        }
    }
    func finishRecording() {
        guard activity == .listening,let file=recorder.finish() else{return}
        guard recorder.heardSpeech else{
            try? FileManager.default.removeItem(at:file);conversationMode=false;activity = .idle
            note="I didn't hear a question. Tap Talk whenever you're ready.";return
        }
        activity = .transcribing
        task=Task { [weak self] in
            guard let self else{return}
            defer{try? FileManager.default.removeItem(at:file)}
            do {
                let text=try await client().transcribe(file:file);try Task.checkCancellation()
                draft=text;await run(text)
            } catch is CancellationError {}
            catch {if !Task.isCancelled{fail(error)}}
        }
    }
    func submit(_ prompt:String?=nil) {
        let text=(prompt ?? draft).trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else{return}
        let continueVoice=conversationMode
        stop();conversationMode=continueVoice;currentScreen=ScreenCapture.screen(atPointer:true);expanded=true
        task=Task { [weak self] in await self?.run(text) }
    }
    private func run(_ text:String) async {
        draft="";error="";note="";response="";sources=[];latestScene=nil;latestSpatial=nil;lastQuestion=text;activity = .thinking
        do {
            let api=try client()
            var input:[[String:Any]]=[]
            for entry in history.suffix(5) {
                input.append(["role":"user","content":entry.question])
                input.append(["role":"assistant","content":entry.answer])
            }
            var content:[[String:Any]]=[]
            var context="User request: \(text)\nLocal date: \(Date().formatted(date:.complete,time:.omitted)).\n"
            if !boards.isEmpty {
                let active=boards.values.filter{$0.window?.isVisible == true}.map(\.boardDocument.board)
                if let data=try? JSONEncoder().encode(active),let json=String(data:data,encoding:.utf8) {
                    context += "Current sketch boards, with editable vector elements: \(json)\n"
                }
            }
            let models=spatialWindows.values.filter{$0.window?.isVisible == true}.map(\.spatialDocument.definition)
            if !models.isEmpty,let data=try? JSONEncoder().encode(models),let json=String(data:data,encoding:.utf8){context += "Current interactive 3D models: \(json)\n"}
            if includeScreen {
                if ScreenCapture.permitted {
                    let snap=try await snapshot();try Task.checkCancellation()
                    context += "Attached screenshot is the current display, \(snap.width) x \(snap.height) pixels. Overlay coordinates map to this whole image.\n"
                    content.append(["type":"input_image","image_url":snap.dataURL,"detail":"high"])
                } else {note="Screen access is off. Drawing from your question.";context += "No screenshot available. Do not guess screen contents.\n"}
            } else {context += "Screen sharing is off. Draw from the request and conversation.\n"}
            content.insert(["type":"input_text","text":context],at:0)
            input.append(["role":"user","content":content])
            if models.isEmpty,text.range(of:"\\b3\\s?d\\b|three.dimensional",options:[.regularExpression,.caseInsensitive]) != nil{prepareSpatialWorkspace()}
            var lastScene:DrawScene?
            var lastSpatial:SpatialScene?
            var finalText=""
            var finished=false
            var liveConstructionOpen=false
            for _ in 0..<18 {
                try Task.checkCancellation()
                let result=try await api.respond(input:input,allowWeb:webEnabled)
                try Task.checkCancellation()
                let output=result["output"] as? [[String:Any]] ?? []
                input.append(contentsOf:output)
                sources.append(contentsOf:OpenAIClient.sources(result))
                let calls=output.filter{$0["type"] as? String == "function_call"}
                let message=OpenAIClient.outputText(result)
                if !message.isEmpty {finalText=message}
                if calls.isEmpty {
                    if liveConstructionOpen{input.append(["role":"user","content":"The live model is still under construction. Continue with build_3d_step, reset=false, and complete=true on the final step. Do not repeat existing parts."]);continue}
                    finished=true;break
                }
                for call in calls {
                    try Task.checkCancellation()
                    let name=call["name"] as? String ?? "",callID=call["call_id"] as? String ?? ""
                    do {
                        switch name {
                        case "find_images":
                            let args=try JSONSerialization.jsonObject(with:Data((call["arguments"] as? String ?? "{}").utf8)) as? [String:String] ?? [:]
                            let images=try await BoardImages.search(query:args["query"] ?? "",source:args["source"] ?? "auto");try Task.checkCancellation()
                            let metadata=String(data:try JSONEncoder().encode(images),encoding:.utf8)!
                            input.append(["type":"function_call_output","call_id":callID,"output":images.isEmpty ? "No images found. Refine the search.":metadata+"\nUse an appropriate retrieved reference now and draw the requested teaching board. A representative photo with a clear caption is enough; do not keep searching for a perfect pose."])
                            trace("image-search",["query":args["query"] ?? "","count":images.count])
                            if !images.isEmpty{input.append(["role":"user","content":BoardImages.content(images)])}
                            for image in images{sources.append((image.title,image.sourceURL))}
                        case "build_3d_step":
                            let step=try JSONDecoder().decode(SpatialBuildStep.self,from:Data((call["arguments"] as? String ?? "{}").utf8))
                            let existing=spatialWindows[step.id]?.spatialDocument.definition
                            let scene=try step.appending(to:existing)
                            let document:SpatialDocument
                            if step.reset{
                                presentation?.cancel();presentation=nil;player.stop()
                                document=applySpatial(scene,synchronized:true);document.liveBuild=true;document.reserveBounds(step.boundsMin,step.boundsMax)
                            }else{
                                guard let current=spatialWindows[step.id]?.spatialDocument else{throw SideAPIError("Start the model before appending parts.")}
                                document=current;document.append(scene,newParts:step.parts);latestSpatial=scene
                            }
                            document.onReplay={ [weak self] in self?.playSpatial(scene) };liveConstructionOpen = !step.complete
                            scheduleSpatialStep(step,document:document,api:api)
                            if let debugDirectory,let data=try? JSONEncoder().encode(scene){try? data.write(to:debugDirectory.appendingPathComponent("last-spatial.json"))}
                            lastSpatial=scene;lastScene=nil;response=scene.summary
                            trace("3d-agent-step",["parts":step.parts.map(\.name),"complete":step.complete,"total":scene.parts.count])
                            input.append(["type":"function_call_output","call_id":callID,"output":step.complete ? "Final parts queued. Construction will finish with narration. Finish briefly, do not repeat the model.":"New parts are building live with narration. Continue build_3d_step with reset=false and only NEW parts. The earlier parts stay in the model. Use complete=true on the final construction step."])
                        case "draw_scene":
                            let args=call["arguments"] as? String ?? "{}"
                            let scene=try JSONDecoder().decode(DrawScene.self,from:Data(args.utf8)).validated()
                            activity = .drawing
                            apply(scene,animate:scene.beats.isEmpty,synchronized:!scene.beats.isEmpty)
                            if !scene.beats.isEmpty{schedulePresentation(scene,api:api)}
                            lastScene=scene;lastSpatial=nil;response=scene.summary
                            input.append(["type":"function_call_output","call_id":callID,
                                "output":"Success. Opened \(scene.boards.count) vector boards and \(scene.overlay.count) desktop annotations. The synchronized pencil animation and narration are running. Shapes are intentionally revealed in speech order. Do not redraw the same scene or correct intentionally unrevealed shapes. Finish briefly. If inspection is necessary, look_at_screen waits for the animation to finish."])
                        case "look_at_screen":
                            guard includeScreen else{throw SideAPIError("Screen sharing is off. Explain from the existing board or request.")}
                            if let presentation{await presentation.value;try Task.checkCancellation()}
                            let snap=try await snapshot(includeAnnotations:true);try Task.checkCancellation()
                            input.append(["type":"function_call_output","call_id":callID,"output":"Fresh screen captured. See the following image. Dimensions \(snap.width)x\(snap.height)."])
                            input.append(["role":"user","content":[["type":"input_image","image_url":snap.dataURL,"detail":"high"]]])
                        case "show_3d":
                            let args=call["arguments"] as? String ?? "{}"
                            let scene=try JSONDecoder().decode(SpatialScene.self,from:Data(args.utf8)).validated()
                            presentation?.cancel();presentation=nil;player.stop()
                            for board in boards.values{board.boardDocument.progress=1}
                            activity = .drawing;let document=applySpatial(scene,synchronized:true);scheduleSpatial(scene,document:document,api:api)
                            lastSpatial=scene;lastScene=nil;response=scene.summary
                            input.append(["type":"function_call_output","call_id":callID,"output":"Success. The model is building LIVE in the left workspace, each named component appearing during its spoken construction step. Temporarily hidden parts are intentional. Inside reveals internal geometry, Spread separates parts. Do not redraw intentionally incomplete construction. look_at_screen waits for completion. Finish briefly. Update the same id for changes."])
                        default:throw SideAPIError("Unknown drawing tool: \(name)")
                        }
                    } catch is CancellationError {throw CancellationError()}
                    catch {
                        input.append(["type":"function_call_output","call_id":callID,"output":"Tool failed: \(error.localizedDescription). Correct the arguments and retry. Nothing was rendered by this call."])
                    }
                }
            }
            guard finished else{throw SideAPIError("The drawing needed too many revisions. Try a smaller part of the question.")}
            response=lastSpatial?.summary ?? lastScene?.summary ?? finalText
            guard !response.isEmpty else{throw SideAPIError("Sol returned no explanation. Try again.")}
            history.append((text,response));if history.count>10{history.removeFirst()}
            if let presentation{await presentation.value;try Task.checkCancellation();self.presentation=nil}
            pendingSpatial?.close();pendingSpatial=nil
            activity = .idle
            let narration=lastSpatial?.narration ?? (lastScene?.narration.isEmpty == false ? lastScene!.narration:finalText)
            if voiceOutput,!narration.isEmpty,lastScene?.beats.isEmpty != false,lastSpatial == nil {await speak(narration,api:api)}
            else {resumeConversation()}
        } catch is CancellationError {}
        catch {if !Task.isCancelled {fail(error)}}
    }
    func snapshot(includeAnnotations:Bool=false) async throws ->ScreenSnapshot {
        var exclude=controlWindowIDs?() ?? []
        if includeAnnotations,let window=overlay.window{exclude.remove(CGWindowID(window.windowNumber))}
        let result=try await capture.capture(displayID:ScreenCapture.displayID(currentScreen),excluding:exclude)
        if let debugDirectory,let base64=result.dataURL.split(separator:",").last,let data=Data(base64Encoded:String(base64)) {
            try? FileManager.default.createDirectory(at:debugDirectory,withIntermediateDirectories:true)
            try? data.write(to:debugDirectory.appendingPathComponent("latest-capture.jpg"))
        }
        return result
    }
    func apply(_ scene:DrawScene,animate:Bool=true,synchronized:Bool=false) {
        latestScene=scene;latestSpatial=nil
        overlay.apply(scene,screen:currentScreen,initiallyHidden:synchronized)
        for board in scene.boards {
            let isNew=boards[board.id] == nil
            let controller=boards[board.id] ?? BoardWindowController(board:board,screen:currentScreen,offset:boards.count%3)
            controller.onClose={ [weak self] in self?.updateDrawingCount() }
            controller.boardDocument.onUserEdit={ [weak self] in self?.stop() }
            boards[board.id]=controller;controller.present(board,animate:animate)
            if isNew,currentScreen.visibleFrame.width>1300,spatialWindows.values.contains(where:{$0.window?.isVisible == true}),let window=controller.window{
                window.setFrameOrigin(NSPoint(x:currentScreen.visibleFrame.maxX-window.frame.width-20,y:window.frame.minY))
            }
            if synchronized{controller.boardDocument.progress=0}
        }
        updateDrawingCount()
        if let directory=debugDirectory {
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if let data=try? JSONEncoder().encode(scene) {try? data.write(to:directory.appendingPathComponent("last-scene.json"))}
            for board in scene.boards {
                let safe=board.id.filter{$0.isLetter || $0.isNumber || $0 == "-"}.prefix(60)
                try? SVGExporter.export(board).write(to:directory.appendingPathComponent("\(safe).svg"),atomically:true,encoding:.utf8)
                let bitmap=DrawingRenderer.image(elements:board.elements,size:CGSize(width:800,height:560),paper:true)
                try? bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("\(safe).png"))
            }
        }
    }
    func prepareSpatialWorkspace(){
        guard pendingSpatial == nil else{return}
        let placeholder=SpatialScene(id:"pending",title:"Building your 3D model",summary:"",narration:"",parts:[])
        let window=SpatialWindowController(definition:placeholder,screen:currentScreen)
        window.spatialDocument.planning=true;pendingSpatial=window;window.present(placeholder);expanded=false
    }
    @discardableResult func applySpatial(_ scene:SpatialScene,synchronized:Bool=false)->SpatialDocument {
        latestSpatial=scene;latestScene=nil
        let controller=spatialWindows[scene.id] ?? pendingSpatial ?? SpatialWindowController(definition:scene,screen:currentScreen)
        if let pendingSpatial,pendingSpatial !== controller{pendingSpatial.close()};pendingSpatial=nil
        for (id,other) in spatialWindows where id != scene.id{other.window?.orderOut(nil);other.spatialDocument.view?.isPlaying=false}
        controller.onClose={ [weak self] in self?.updateDrawingCount() }
        controller.spatialDocument.onAsk={ [weak self] part in self?.submit("Explain the \(part) on the current \(scene.title) model out loud. Keep this model visible with its existing geometry. Answer without rebuilding or replaying it.") }
        controller.spatialDocument.onReplay={ [weak self] in self?.playSpatial(scene) }
        spatialWindows[scene.id]=controller;activeSpatialID=scene.id;controller.present(scene);expanded=false
        if synchronized{controller.spatialDocument.beginConstruction()};updateDrawingCount()
        if let debugDirectory {
            try? FileManager.default.createDirectory(at:debugDirectory,withIntermediateDirectories:true)
            if let data=try? JSONEncoder().encode(scene){try? data.write(to:debugDirectory.appendingPathComponent("last-spatial.json"))}
        }
        return controller.spatialDocument
    }
    func playSpatial(_ scene:SpatialScene){
        stop();response=scene.summary
        do{
            let api=try client(),document=applySpatial(scene,synchronized:true)
            scheduleSpatial(scene,document:document,api:api)
            task=Task{[weak self] in await self?.presentation?.value;if !Task.isCancelled{self?.presentation=nil;self?.resumeConversation()}}
        }catch{fail(error)}
    }
    private func scheduleSpatial(_ scene:SpatialScene,document:SpatialDocument,api:OpenAIClient){
        presentation?.cancel()
        let beats=scene.constructionBeats
        let jobs:[Task<Data,Error>]=voiceOutput ? beats.map{beat in Task{try await api.speech(beat.narration)}}:[]
        presentation=Task{[weak self] in
            defer{jobs.forEach{$0.cancel()}}
            guard let self else{return}
            for (index,beat) in beats.enumerated(){
                guard !Task.isCancelled else{return}
                var audio:Data?
                if voiceOutput,index<jobs.count{
                    do{audio=try await withTaskCancellationHandler(operation:{try await jobs[index].value},onCancel:{jobs.forEach{$0.cancel()}})}
                    catch{if Task.isCancelled{return};note="Using the Mac voice for this explanation."}
                }
                guard !Task.isCancelled else{return}
                var duration=max(1.2,min(5,Double(beat.narration.split(separator:" ").count)*0.19))
                if voiceOutput{
                    activity = .speaking
                    if let audio{do{duration=try player.play(audio)}catch{player.speakLocally(beat.narration);duration=Double(beat.narration.split(separator:" ").count)*0.4+0.6}}
                    else{player.speakLocally(beat.narration);duration=Double(beat.narration.split(separator:" ").count)*0.4+0.6}
                }else{activity = .drawing}
                let began=Date.timeIntervalSinceReferenceDate
                document.step=index+1;document.caption=beat.narration;document.inside=beat.interior;document.applyAppearance()
                trace("3d-cue-start",["cue":index,"narration":beat.narration,"duration":duration,"parts":beat.parts,"interior":beat.interior])
                await document.reveal(beat.parts,duration:duration*0.85)
                guard !Task.isCancelled else{return}
                trace("3d-parts-added",["cue":index,"visible":document.addedCount,"total":document.components.count])
                let remaining=duration-(Date.timeIntervalSinceReferenceDate-began)
                if remaining>0{do{try await Task.sleep(for:.seconds(remaining))}catch{return}}
            }
            if !Task.isCancelled{document.inside=scene.showInterior ?? false;document.finishConstruction();activity = .idle;trace("3d-construction-finished",["parts":document.components.count])}
        }
    }
    private func scheduleSpatialStep(_ step:SpatialBuildStep,document:SpatialDocument,api:OpenAIClient){
        let previous=presentation
        let audioJob:Task<Data,Error>?=voiceOutput ? Task{try await api.speech(step.narration)}:nil
        presentation=Task{[weak self] in
            defer{audioJob?.cancel()}
            await withTaskCancellationHandler(operation:{await previous?.value},onCancel:{previous?.cancel()})
            guard let self,!Task.isCancelled else{return}
            var audio:Data?
            if let audioJob{do{audio=try await withTaskCancellationHandler(operation:{try await audioJob.value},onCancel:{audioJob.cancel()})}catch{if Task.isCancelled{return}}}
            guard !Task.isCancelled else{return}
            var duration=max(1.2,min(5,Double(step.narration.split(separator:" ").count)*0.19))
            if voiceOutput{
                activity = .speaking
                if let audio{do{duration=try player.play(audio)}catch{player.speakLocally(step.narration);duration=Double(step.narration.split(separator:" ").count)*0.4+0.6}}
                else{player.speakLocally(step.narration);duration=Double(step.narration.split(separator:" ").count)*0.4+0.6}
            }else{activity = .drawing}
            document.step+=1;document.caption=step.narration;document.inside=step.interior;document.applyAppearance()
            let began=Date.timeIntervalSinceReferenceDate
            trace("3d-live-cue-start",["step":document.step,"parts":step.parts.map(\.name),"duration":duration,"narration":step.narration])
            await document.reveal(step.parts.map(\.name),duration:duration*0.85)
            guard !Task.isCancelled else{return}
            trace("3d-live-parts-added",["step":document.step,"visible":document.addedCount])
            let remaining=duration-(Date.timeIntervalSinceReferenceDate-began)
            if remaining>0{do{try await Task.sleep(for:.seconds(remaining))}catch{return}}
            if step.complete{document.inside=step.showInterior;document.finishConstruction();trace("3d-live-complete",["parts":document.components.count])}
        }
    }
    func updateDrawingCount(){boardCount=boards.values.filter{$0.window?.isVisible == true}.count+spatialWindows.values.filter{$0.window?.isVisible == true}.count}
    private func schedulePresentation(_ scene:DrawScene,api:OpenAIClient) {
        presentation?.cancel()
        let speechJobs:[Task<Data,Error>]=voiceOutput ? scene.beats.map{beat in Task{try await api.speech(beat.narration)}}:[]
        presentation=Task { [weak self] in
            defer{speechJobs.forEach{$0.cancel()}}
            guard let self else{return}
            for (index,beat) in scene.beats.enumerated() {
                if Task.isCancelled{return}
                var audio:Data?
                if voiceOutput,index<speechJobs.count {
                    do {
                        audio=try await withTaskCancellationHandler(operation:{try await speechJobs[index].value},onCancel:{speechJobs.forEach{$0.cancel()}})
                    }catch{if Task.isCancelled{return};note="Using the Mac voice for this explanation."}
                }
                if Task.isCancelled{return}
                var duration=max(0.9,min(3,Double(beat.narration.split(separator:" ").count)*0.17))
                if voiceOutput {
                    activity = .speaking
                    if let audio {
                        do{duration=try player.play(audio)}catch{player.speakLocally(beat.narration);duration=Double(beat.narration.split(separator:" ").count)*0.4+0.6}
                    }else{player.speakLocally(beat.narration);duration=Double(beat.narration.split(separator:" ").count)*0.4+0.6}
                }else{activity = .drawing}
                let began=Date.timeIntervalSinceReferenceDate
                trace("cue-start",["cue":index,"narration":beat.narration,"duration":duration,"spoken":voiceOutput])
                for reveal in beat.reveals{boards[reveal.boardID]?.boardDocument.caption=beat.narration}
                trace("pencil-start",["cue":index,"reveals":beat.reveals.map{["boardID":$0.boardID,"throughElement":$0.throughElement]}])
                await withTaskGroup(of:Void.self) {group in
                    for reveal in beat.reveals {
                        if let document=self.boards[reveal.boardID]?.boardDocument {
                            group.addTask{@MainActor in await document.reveal(through:reveal.throughElement,duration:duration*0.88)}
                        }
                    }
                    group.addTask{@MainActor in await self.overlay.reveal(through:beat.overlayThroughElement,duration:duration*0.88)}
                }
                if Task.isCancelled{return}
                trace("pencil-finished",["cue":index])
                let remaining=duration-(Date.timeIntervalSinceReferenceDate-began)
                if remaining>0{do{try await Task.sleep(for:.seconds(remaining))}catch{return}}
                trace("cue-finished",["cue":index])
            }
            if !Task.isCancelled{activity = .idle}
        }
    }
    private func trace(_ event:String,_ fields:[String:Any]=[:]) {
        guard let debugDirectory else{return}
        try? FileManager.default.createDirectory(at:debugDirectory,withIntermediateDirectories:true)
        var value=fields;value["event"]=event;value["time"]=Date().timeIntervalSince1970
        guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else{return}
        let file=debugDirectory.appendingPathComponent("timing.jsonl")
        if !FileManager.default.fileExists(atPath:file.path){FileManager.default.createFile(atPath:file.path,contents:nil)}
        if let handle=try? FileHandle(forWritingTo:file){defer{try? handle.close()};_=try? handle.seekToEnd();try? handle.write(contentsOf:data+Data([10]))}
    }
    private func speak(_ text:String,api:OpenAIClient) async {
        do {
            activity = .speaking
            let audio=try await api.speech(text);try Task.checkCancellation()
            guard voiceOutput else{activity = .idle;return}
            try player.play(audio)
        } catch is CancellationError {}
        catch {if !Task.isCancelled{note="Using the Mac voice because online speech was unavailable.";player.speakLocally(text)}}
    }
    private func resumeConversation() {
        guard conversationMode,!Task.isCancelled else{return}
        task=Task{[weak self] in
            do {
                try await Task.sleep(for:.milliseconds(450))
                guard let self,conversationMode else{return}
                try await recorder.start();try Task.checkCancellation();activity = .listening
                trace("conversation-listening",["microphoneRecording":recorder.isRecording])
            }catch is CancellationError{}catch{if !Task.isCancelled{self?.fail(error)}}
        }
    }
    func replay() {
        if let latestSpatial,let controller=spatialWindows[latestSpatial.id]{controller.present(latestSpatial);expanded=false;return}
        guard !response.isEmpty else{return}
        let continueVoice=conversationMode
        stop();conversationMode=continueVoice
        task=Task { [weak self] in
            guard let self else{return}
            do {
                let api=try client()
                if let latestScene,!latestScene.beats.isEmpty {
                    apply(latestScene,animate:false,synchronized:true);schedulePresentation(latestScene,api:api)
                    await presentation?.value;try Task.checkCancellation();presentation=nil;resumeConversation()
                }else if let latestSpatial{
                    let document=applySpatial(latestSpatial,synchronized:true);scheduleSpatial(latestSpatial,document:document,api:api)
                    await presentation?.value;try Task.checkCancellation();presentation=nil;resumeConversation()
                }else{
                    await speak(latestSpatial?.narration ?? response,api:api)
                }
            }catch{if !Task.isCancelled{fail(error)}}
        }
    }
    func showSpatial(){
        guard let id=activeSpatialID,let controller=spatialWindows[id] else{return}
        controller.present(controller.spatialDocument.definition);expanded=false;updateDrawingCount()
    }
    func stop(){conversationMode=false;task?.cancel();task=nil;presentation?.cancel();presentation=nil;recorder.cancel();player.stop();for b in boards.values{b.boardDocument.animation?.cancel();b.boardDocument.progress=1};for s in spatialWindows.values where s.spatialDocument.building{s.spatialDocument.finishConstruction()};pendingSpatial?.close();pendingSpatial=nil;overlay.finishReveal();level=0;activity = .idle}
    func fail(_ cause:Error){conversationMode=false;recorder.cancel();pendingSpatial?.close();pendingSpatial=nil;error=cause.localizedDescription;activity = .failed;expanded=true}
    func clearDrawings(){stop();latestScene=nil;latestSpatial=nil;activeSpatialID=nil;overlay.clear();for b in boards.values{b.close()};for s in spatialWindows.values{s.close()};boards=[:];spatialWindows=[:];boardCount=0}
    func newConversation(){stop();history=[];response="";lastQuestion="";error="";sources=[];clearDrawings()}
    func drawingCheck(){stop();error="";apply(ExampleScenes.tensor);response=ExampleScenes.tensor.summary;expanded=true}
    func spatialCheck(){stop();error="";applySpatial(SpatialExamples.aircraft);response=SpatialExamples.aircraft.summary;expanded=true}
    func playScene(_ scene:DrawScene) {
        stop();expanded=true;response=scene.summary
        do {
            let api=try client();apply(scene,animate:scene.beats.isEmpty,synchronized:!scene.beats.isEmpty)
            if !scene.beats.isEmpty {
                schedulePresentation(scene,api:api)
                task=Task{[weak self] in await self?.presentation?.value;if !Task.isCancelled{self?.presentation=nil}}
            }
        }catch{fail(error)}
    }
    func voiceLoopbackCheck(continueConversation:Bool=false) {
        stop();expanded=true;lastQuestion="Testing microphone, transcription, Sol, and drawing together."
        task=Task{[weak self] in
            guard let self else{return}
            do {
                let api=try client()
                let sample=try await api.speech("Open a sketch board and draw a blue triangle.")
                try Task.checkCancellation();try await recorder.start(voiceProcessing:false);activity = .listening
                let duration=try player.play(sample)
                try await Task.sleep(for:.seconds(duration+0.5));try Task.checkCancellation()
                guard let file=recorder.finish() else{throw SideAPIError("Microphone check could not produce a recording.")}
                defer{try? FileManager.default.removeItem(at:file)}
                activity = .transcribing
                let text=try await api.transcribe(file:file)
                trace("voice-loopback",["transcript":text,"passed":text.lowercased().contains("triangle")])
                guard text.lowercased().contains("triangle") else{throw SideAPIError("The microphone did not hear the test sentence clearly. Try speaking a question using Talk.")}
                conversationMode=continueConversation
                await run(text)
            }catch is CancellationError{}catch{if !Task.isCancelled{fail(error)}}
        }
    }
}
