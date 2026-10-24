import Foundation
import AppKit
import AVFoundation
import Vision
import SceneKit
import Metal
import SideCore

struct CheckFailure:Error,CustomStringConvertible {let description:String}
func expect(_ condition:@autoclosure()->Bool,_ message:String) throws {
    if !condition(){throw CheckFailure(description:message)}
}

final class StubProtocol:URLProtocol {
    static var responder:((URLRequest)throws->(Int,Data))!
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        do {
            let (status,data)=try Self.responder(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        }catch{client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading(){}
}
final class PendingProtocol:URLProtocol {
    static var didStart:(()->Void)?
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){Self.didStart?()}
    override func stopLoading(){}
}

@main struct SideChecks {
    @MainActor static func main() async {
        let args=CommandLine.arguments
        if args.contains("--image-library-check"){
            do{
                for (query,source) in [("astronaut spacewalk","nasa"),("bicycle","commons")]{let images=try await BoardImages.search(query:query,source:source);try expect(!images.isEmpty,"\(source) returned no photos");print("PASS LIVE \(source) retrieved \(images.count) credited reference images")}
            }catch{print("FAIL \(error)");exit(1)}
            return
        }
        if args.contains("--render-spatial-existing") {
            do {
                let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/live-3d")
                for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where file.pathExtension == "json" {
                    let scene=try JSONDecoder().decode(SpatialScene.self,from:Data(contentsOf:file)).validated()
                    try renderSpatial(scene,to:file.deletingPathExtension().appendingPathExtension("png"))
                }
                print("Re-rendered saved 3D scenes.")
            }catch{print("FAIL: \(error)");exit(1)}
            return
        }
        if args.contains("--render-existing") {
            let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/live-2d")
            do {
                for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where file.pathExtension == "json" {
                    let scene=try JSONDecoder().decode(DrawScene.self,from:Data(contentsOf:file)).validated()
                    for (i,b) in scene.boards.enumerated() {
                        let stem=file.deletingPathExtension().lastPathComponent+"-\(i)"
                        try DrawingRenderer.image(elements:b.elements,size:CGSize(width:800,height:560),paper:true).representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(stem+".png"))
                        try SVGExporter.export(b).write(to:directory.appendingPathComponent(stem+".svg"),atomically:true,encoding:.utf8)
                    }
                }
                print("Re-rendered saved live drawings.")
            }catch{print("FAIL: \(error)");exit(1)}
            return
        }
        if let i=args.firstIndex(of:"--import-key-from"),args.count>i+1 {
            do {try KeyStore.importDotEnv(at:URL(fileURLWithPath:args[i+1]));print("API key imported into Keychain. Secret not printed.")}
            catch{print("FAIL: \(error.localizedDescription)");exit(1)}
            return
        }
        var failures=0,passed=0
        func check(_ name:String,_ body:() async throws ->Void) async {
            do {try await body();passed+=1;print("PASS \(name)")}
            catch{failures+=1;print("FAIL \(name): \(error)")}
            fflush(stdout)
        }
        await check("reference tensor and JSON round trip") {
            let scene=try ExampleScenes.tensor.validated(),cells=scene.boards[0].elements.filter{$0.kind == "rect"}
            try expect(cells.count==8,"Expected eight cells")
            try expect(cells.map(\.text)==["18","47","56","57","58","1","15","47"],"Cell values changed")
            try expect(cells.first{$0.color == "blue"}?.text == "15","Wrong selected cell")
            let decoded=try JSONDecoder().decode(DrawScene.self,from:JSONEncoder().encode(scene))
            try expect(decoded==scene,"JSON did not round trip")
        }
        await check("normalized coordinates on Retina and resized boards") {
            let e=DrawElement("rect",x:100,y:200,w:300,h:400)
            let r=DrawingRenderer.rect(e,in:CGSize(width:1512,height:982))
            try expect(abs(r.origin.x-151.2)<0.0001 && abs(r.origin.y-196.4)<0.0001,"Wrong origin")
            try expect(abs(r.width-453.6)<0.0001 && abs(r.height-392.8)<0.0001,"Wrong size")
            try expect(DrawingRenderer.point(DrawPoint(500,500),in:CGSize(width:800,height:560)) == CGPoint(x:400,y:280),"Wrong resized center")
        }
        await check("invalid geometry and duplicate ids rejected atomically") {
            for e in [DrawElement("rect",x:900,y:0,w:200,h:20),DrawElement("text",x:0,y:0,w:0,h:40),
                      DrawElement("arrow",x:20,y:20,w:-100,h:20),DrawElement("path",x:0,y:0,points:[DrawPoint(.nan,4)])] {
                var rejected=false;do{_=try DrawScene(summary:"bad",overlay:[e]).validated()}catch{rejected=true}
                try expect(rejected,"Accepted invalid \(e.kind)")
            }
            _=try DrawScene(summary:"left arrow",overlay:[DrawElement("arrow",x:900,y:900,w:-800,h:-800)]).validated()
            let b=SketchBoard(title:"A",elements:[])
            var rejected=false;do{_=try DrawScene(summary:"duplicate",boards:[b,b]).validated()}catch{rejected=true}
            try expect(rejected,"Duplicate board ids accepted")
        }
        await check("SVG XML escaping, wrapping and reverse arrow direction") {
            let b=SketchBoard(title:"A & <B>",elements:[
                DrawElement("text",x:40,y:40,w:800,h:250,text:"A < B & C > D\nsecond line"),
                DrawElement("arrow",x:900,y:800,w:-500,h:-400,color:"blue")])
            let svg=SVGExporter.export(b)
            try expect(XMLParser(data:Data(svg.utf8)).parse(),"Invalid XML")
            try expect(svg.contains("A &lt; B &amp; C &gt; D"),"Text not escaped")
            try expect(svg.contains("M 720.00 448.00 L 320.00 224.00"),"Reverse arrow flipped: \(svg)")
            try expect(svg.contains("second line"),"Second line missing")
        }
        await check("renderer produces ink at 2x and transparent overlays") {
            let e=DrawElement("rect",x:250,y:250,w:500,h:500,color:"blue",fill:"blue")
            let board=DrawingRenderer.image(elements:[e],size:CGSize(width:200,height:200),scale:2,paper:true)
            try expect(board.pixelsWide==400 && board.pixelsHigh==400,"Wrong Retina bitmap size")
            guard let middle=board.colorAt(x:200,y:200)?.usingColorSpace(.sRGB),let corner=board.colorAt(x:10,y:10)?.usingColorSpace(.sRGB) else{throw CheckFailure(description:"No pixel data")}
            let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts")
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            try board.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("renderer-check.png"))
            try expect(middle.redComponent<corner.redComponent,"Shape did not render in correct location. Center: \(middle) Corner: \(corner)")
            let overlay=DrawingRenderer.image(elements:[e],size:CGSize(width:200,height:200),scale:1,paper:false)
            try expect(overlay.colorAt(x:1,y:1)?.alphaComponent==0,"Overlay background is opaque")
            try expect((overlay.colorAt(x:100,y:100)?.alphaComponent ?? 0)>0,"Overlay ink missing")
        }
        await check("all seven 2D primitives render and export") {
            let kinds=["text","rect","ellipse","arrow","line","path","highlight"]
            let elements=kinds.enumerated().map{i,kind in
                DrawElement(kind,x:50,y:Double(30+i*130),w:500,h:100,text:kind,color:"blue",fill:"green",points:kind == "path" ? [DrawPoint(20,650),DrawPoint(700,750)]:[])
            }
            let board=SketchBoard(title:"Primitives",elements:elements)
            _=try DrawScene(summary:"all",boards:[board]).validated()
            try expect(XMLParser(data:Data(SVGExporter.export(board).utf8)).parse(),"Invalid primitive SVG")
            try expect(DrawingRenderer.image(elements:elements,size:CGSize(width:800,height:560),paper:true).representation(using:.png,properties:[:]) != nil,"PNG rendering failed")
        }
        await check("exported text is upright and readable by OCR") {
            let element=DrawElement("text",x:80,y:120,w:820,h:500,text:"Two rows and four columns",fontSize:34)
            let bitmap=DrawingRenderer.image(elements:[element],size:CGSize(width:800,height:300),paper:true)
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage:bitmap.cgImage!,options:[:]).perform([request])
            let text=(request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:" ").lowercased()
            try expect(text.contains("two rows and four columns"),"Exported text was inverted or unreadable: \(text)")
        }
        await check("long labels automatically fit their boxes") {
            let font=TextFitter.font(for:"dy/dx = (dy/du)(du/dx)\n= 6x/(3x² − 1)",preferredSize:32,in:CGSize(width:320,height:70))
            try expect(font.pointSize<32 && font.pointSize>=14,"Text was not resized legibly")
        }
        await check("pencil moves at constant arc length and never pops a full shape") {
            let points=[CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:100,y:0)]
            let half=PencilPath.trimmed([points],fraction:0.5)
            try expect(half.last?.last==CGPoint(x:50,y:0),"Pencil speed depends on point density")
            try expect(PencilPath.trimmed([points],fraction:0).isEmpty,"Stroke appears before its cue")
            let triangle=DrawElement("path",x:0,y:0,points:[DrawPoint(150,750),DrawPoint(500,150),DrawPoint(850,750),DrawPoint(150,750)])
            let strokes=PencilPath.strokes(for:triangle,in:CGSize(width:800,height:560))
            try expect(PencilPath.length(PencilPath.trimmed(strokes,fraction:0.5)[0])<PencilPath.length(strokes[0]),"Full triangle popped in")
            let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/pencil")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for i in 0...30 {
                let bitmap=DrawingRenderer.image(elements:[triangle],size:CGSize(width:800,height:560),scale:1,paper:true,progress:Double(i)/30)
                try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(String(format:"frame-%03d.png",i)))
            }
        }
        await check("speech cues reject skipped, decreasing, or unknown element counts") {
            let b=SketchBoard(title:"Triangle",elements:[DrawElement("line",x:10,y:10,w:100,h:100)])
            let good=DrawScene(summary:"triangle",boards:[b],beats:[DrawBeat(narration:"Imagine a triangle",reveals:[BoardReveal(boardID:"main",throughElement:1)])])
            _=try good.validated()
            var bad=good;bad.beats[0].reveals[0].throughElement=0
            var rejected=false;do{_=try bad.validated()}catch{rejected=true}
            try expect(rejected,"Hidden final elements accepted")
            bad=good;bad.beats[0].reveals[0].boardID="unknown"
            rejected=false;do{_=try bad.validated()}catch{rejected=true}
            try expect(rejected,"Unknown board cue accepted")
        }
        await check("strict tool schema recursively requires all fields") {
            func visit(_ value:Any) throws {
                if let d=value as? [String:Any] {
                    if d["type"] as? String == "object" {
                        let p=d["properties"] as? [String:Any] ?? [:]
                        try expect(Set(d["required"] as? [String] ?? [])==Set(p.keys),"Missing required field")
                        try expect(d["additionalProperties"] as? Bool==false,"Extra properties allowed")
                    }
                    for v in d.values{try visit(v)}
                }else if let a=value as? [Any]{for v in a{try visit(v)}}
            }
            try visit(SceneSchema.schema);try visit(SpatialSchema.schema);try visit(SpatialSchema.liveTool)
        }
        func stubAPI()->OpenAIClient {
            let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[StubProtocol.self]
            return OpenAIClient(key:"sk-test-only-never-a-real-key",session:URLSession(configuration:c))
        }
        await check("Sol API request, private storage, tools, web toggle") {
            StubProtocol.responder={request in
                let bytes=request.httpBody ?? Data(reading:request.httpBodyStream!)
                let body=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
                try expect(body["model"] as? String=="gpt-6.1-sol","Wrong model")
                try expect(body["store"] as? Bool==false,"Remote storage enabled")
                let tools=body["tools"] as! [[String:Any]]
                try expect(tools.contains{$0["name"] as? String=="draw_scene"},"No drawing tool")
                try expect(!tools.contains{$0["type"] as? String=="web_search"},"Web toggle ignored")
                return(200,Data("{\"status\":\"completed\",\"output\":[]}".utf8))
            }
            _=try await stubAPI().respond(input:[["role":"user","content":"Draw a graph"]],allowWeb:false)
        }
        await check("API failures redact credentials") {
            StubProtocol.responder={_ in(401,Data("{\"error\":{\"message\":\"Incorrect API key sk-test-only-never-a-real-key\"}}".utf8))}
            var rejected=false
            do{_=try await stubAPI().respond(input:[])}catch{
                rejected=true;try expect(error.localizedDescription.contains("[redacted]"),"Key was not redacted")
                try expect(!error.localizedDescription.contains("sk-test"),"Secret leaked")
            }
            try expect(rejected,"401 was not rejected")
        }
        await check("silence is not submitted as a question") {
            StubProtocol.responder={_ in(200,Data("{\"text\":\" \"}".utf8))}
            let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".m4a")
            try Data([1,2,3]).write(to:file);defer{try? FileManager.default.removeItem(at:file)}
            var rejected=false;do{_=try await stubAPI().transcribe(file:file)}catch{rejected=true}
            try expect(rejected,"Empty speech accepted")
        }
        await check("cancelling an in-flight request stays a cancellation") {
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[PendingProtocol.self]
            let api=OpenAIClient(key:"sk-test-only-never-a-real-key",session:URLSession(configuration:configuration))
            var request:Task<[String:Any],Error>!
            await withCheckedContinuation{(started:CheckedContinuation<Void,Never>) in
                PendingProtocol.didStart={started.resume()}
                request=Task{try await api.respond(input:[["role":"user","content":"Draw a triangle"]])}
            }
            request.cancel()
            do{_=try await request.value;throw CheckFailure(description:"Cancelled request returned normally")}
            catch is CancellationError{}
            PendingProtocol.didStart=nil
        }
        await check("a click does not count as a spoken question") {
            var gate=SpeechEvidence()
            try expect(!gate.update(aboveThreshold:true,interval:0.07),"A single click opened the speech gate")
            for _ in 0..<20{try expect(!gate.update(aboveThreshold:false,interval:0.07),"Silence opened the speech gate")}
            var speechDetected=false
            for _ in 0..<6{speechDetected = gate.update(aboveThreshold:true,interval:0.07) || speechDetected}
            try expect(speechDetected,"Sustained speech was rejected")
        }
        await check("3D aircraft is real geometry with camera and selectable structures") {
            let definition=try SpatialExamples.aircraft.validated(),scene=SpatialBuilder.build(definition)
            try expect(scene.rootNode.childNode(withName:"camera",recursively:false)?.camera != nil,"No 3D camera")
            let content=scene.rootNode.childNode(withName:"content",recursively:false)!
            try expect(content.childNodes.count==definition.parts.count,"Scene graph lost a part")
            try expect(content.childNode(withName:"Right wing",recursively:true)?.geometry != nil,"Aircraft has no actual wing geometry")
            try expect(content.childNode(withName:"Left engine",recursively:true) is PartNode,"Aircraft parts cannot be inspected")
            let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/spatial")
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try renderSpatial(definition,to:output.appendingPathComponent("aircraft.png"))
            let archive=output.appendingPathComponent("aircraft.scn")
            try expect(scene.write(to:archive,options:nil,delegate:nil,progressHandler:nil),"3D export failed")
            let restored=try SCNScene(url:archive,options:nil)
            try expect(restored.rootNode.childNode(withName:"content",recursively:false)?.childNodes.count==definition.parts.count,"3D export lost geometry")
        }
        await check("3D malformed meshes and duplicate names are rejected") {
            let invalid=SpatialPart(name:"bad",kind:"mesh",vertices:[Vector3(0,0,0),Vector3(1,0,0),Vector3(0,1,0)],triangles:[0,1,8])
            var rejected=false
            do{_=try SpatialScene(title:"bad",summary:"bad",narration:"",parts:[invalid]).validated()}catch{rejected=true}
            try expect(rejected,"Mesh with invalid indices was accepted")
            let part=SpatialPart(name:"same",kind:"sphere")
            rejected=false;do{_=try SpatialScene(title:"dup",summary:"",narration:"",parts:[part,part]).validated()}catch{rejected=true}
            try expect(rejected,"Duplicate part names accepted")
        }
        await check("3D arrows point to the requested signed world direction") {
            let arrow=SpatialBuilder.node(SpatialPart(name:"Down",kind:"arrow",size:Vector3(0,-3,0)))
            let b=arrow.boundingBox
            try expect(b.min.y < -2.95 && b.max.y<0.2,"Weight arrow points the wrong way")
        }
        await check("3D wide labels preserve letter proportions"){
            let part=SpatialBuilder.node(SpatialPart(name:"Wide label",kind:"label",size:Vector3(6,0.6,0.1),label:"A readable wide label"))
            let plane=part.childNodes[0].geometry as! SCNPlane
            let texture=plane.firstMaterial!.diffuse.contents as! NSImage
            try expect(abs(texture.size.width/texture.size.height-Double(plane.width/plane.height))<0.01,"Wide card stretched its text texture")
        }
        await check("3D construction covers real internal parts and rejects missing steps") {
            let definition=SpatialExamples.aircraft,scene=SpatialBuilder.build(definition)
            let components=SpatialBuilder.components(in:scene)
            try expect(Set(components.map(\.componentKey))==Set(SpatialBuilder.componentKeys(definition.parts)),"Construction keys do not match actual geometry")
            try expect(components.filter{$0.layer == "interior"}.count>=15,"Aircraft has no real internal assembly")
            try expect(components.contains{$0.partName == "Left turbine" && $0.geometry != nil},"Engine core geometry missing")
            try expect(components.contains{$0.partName == "Fuselage" && $0.layer == "shell"},"Outer shell cannot be opened")
            var good=definition;good.beats=[SpatialBeat(narration:"Build every component",parts:definition.parts.map(\.name),interior:true)]
            _=try good.validated()
            good.beats=[SpatialBeat(narration:"Only a wing",parts:["Aircraft/Left wing"])]
            var rejected=false;do{_=try good.validated()}catch{rejected=true}
            try expect(rejected,"Incomplete construction was accepted")
            good.beats=[SpatialBeat(narration:"Unknown",parts:["Imaginary component"])]
            rejected=false;do{_=try good.validated()}catch{rejected=true}
            try expect(rejected,"Unknown construction component was accepted")
        }
        await check("3D zoom remains centered, bounded, and resettable") {
            var orbit=SpatialOrbit(min:Vector3(-5,-3,-6),max:Vector3(5,3,6),aspect:0.98)
            let home=orbit
            for _ in 0..<100{orbit.zoom(delta:-100)}
            try expect(orbit.distance>=orbit.homeDistance*0.38,"Zoom passed through the model")
            try expect(orbit.target==home.target,"Zoom panned the model away")
            for _ in 0..<100{orbit.rotate(dx:73,dy:100);orbit.zoom(delta:100)}
            try expect(orbit.distance<=orbit.homeDistance*2.8 && orbit.pitch<=1.25,"Camera left its bounds")
            try expect([orbit.position.x,orbit.position.y,orbit.position.z].allSatisfy(\.isFinite),"Camera became invalid")
            orbit.reset();try expect(orbit==home,"Reset did not restore the exact home view")
        }
        await check("live 3D steps append without losing earlier geometry"){
            let first=SpatialBuildStep(id:"test-live",title:"Live assembly",summary:"Two components",narration:"First the shaft.",parts:[SpatialPart(name:"Shaft",kind:"cylinder",layer:"interior")],reset:true,complete:false,interior:true,showInterior:true,boundsMin:Vector3(-3,-3,-3),boundsMax:Vector3(3,3,3))
            let initial=try first.appending(to:nil)
            var next=first;next.reset=false;next.complete=true;next.narration="Then the outer housing.";next.parts=[SpatialPart(name:"Housing",kind:"cylinder",size:Vector3(2,2,2),layer:"shell")]
            let final=try next.appending(to:initial)
            try expect(final.parts.map(\.name)==["Shaft","Housing"] && final.beats?.count==2,"Append replaced the earlier parts")
            var rejected=false;do{_=try next.appending(to:final)}catch{rejected=true}
            try expect(rejected,"Duplicate live parts were accepted")
        }
        await check("reference photos preserve orientation, credits and offline SVG export"){
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:120,pixelsHigh:120,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            let pixels=bitmap.bitmapData!
            for y in 0..<120{for x in 0..<120{let i=y*bitmap.bytesPerRow+x*4;pixels[i]=y<60 ? 255:0;pixels[i+1]=0;pixels[i+2]=y<60 ? 0:255;pixels[i+3]=255}}
            let asset=try BoardImages.store(bitmap.representation(using:.png,properties:[:])!,title:"Orientation test",credit:"Test <author> & source",sourceURL:"https://example.com/side-orientation-test")
            let element=DrawElement("image",x:100,y:100,w:800,h:800,imageID:asset.id)
            let board=SketchBoard(title:"Image and vectors",elements:[element])
            _=try DrawScene(summary:"image",boards:[board]).validated()
            let rendered=DrawingRenderer.image(elements:board.elements,size:CGSize(width:200,height:200),scale:1,paper:true)
            let top=rendered.colorAt(x:100,y:50)!.usingColorSpace(.sRGB)!,bottom=rendered.colorAt(x:100,y:130)!.usingColorSpace(.sRGB)!
            try expect(top.redComponent>0.8 && bottom.blueComponent>0.8,"Photo was inverted or missing")
            let svg=SVGExporter.export(board)
            try expect(XMLParser(data:Data(svg.utf8)).parse() && svg.contains("data:image/png;base64,") && svg.contains("Test &lt;author&gt; &amp; source"),"Photo or attribution missing in exported SVG")
            try expect(BoardImages.data("../../.dev.vars")==nil,"Image ID allowed a file path")
        }
        if args.contains("--space-cases") || args.contains("--photo-case"){
            let credentialFile=args.firstIndex(of:"--key-file").flatMap{i in args.count>i+1 ? args[i+1]:nil}
            let key=credentialFile.flatMap{try? KeyStore.readDotEnv(at:URL(fileURLWithPath:$0))} ?? KeyStore.load()
            guard let key else{print("FAIL Missing authorized key");exit(1)}
            let api=OpenAIClient(key:key),out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/space-cases")
            try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            await check("LIVE image libraries retrieve real NASA and Commons photos"){
                let nasa=try await BoardImages.search(query:"astronaut spacewalk",source:"nasa")
                try expect(!nasa.isEmpty && nasa[0].sourceURL.contains("nasa.gov"),"NASA image retrieval failed")
                let commons=try await BoardImages.search(query:"bicycle",source:"commons")
                try expect(!commons.isEmpty && !commons[0].credit.isEmpty,"Commons reference retrieval failed")
            }
            for (id,prompt) in [
                ("astronaut-photo","Get a real NASA astronaut spacewalk photo using find_images. Open a 2D teaching board with the photo on the left and a clear hand-drawn spacesuit system diagram on the right. Explain oxygen supply, cooling and the protective helmet in short synchronized spoken beats. Include the actual image, credit and a source link. Do not make a 3D model."),
                ("orbit","Draw a 2D explanation of why astronauts float in orbit, with Earth, the spacecraft, velocity tangent and gravity toward Earth. Show continuous free fall, not zero gravity. Use a roomy board and three short spoken teaching beats. Look up a NASA source and include its link."),
                ("spacewalk-plan","Draw a 2D astronaut spacewalk planning flow: prepare suit, airlock, tether, task, return. Use five labeled boxes and arrows, highlight the tether safety step, and explain it in three short speech-synchronized stages. This is a conceptual lesson, not operational EVA guidance.")
            ]{
                if args.contains("--photo-case"),id != "astronaut-photo"{continue}
                await check("LIVE fresh 2D case: \(id)"){
                    let (scene,_)=try await liveDrawing(api:api,prompt:prompt)
                    if id=="astronaut-photo"{try expect(scene.boards.flatMap(\.elements).contains{$0.kind == "image"},"No retrieved photo on the drawing board")}
                    try JSONEncoder().encode(scene).write(to:out.appendingPathComponent(id+".json"))
                    for (i,board) in scene.boards.enumerated(){try SVGExporter.export(board).write(to:out.appendingPathComponent("\(id)-\(i).svg"),atomically:true,encoding:.utf8);try DrawingRenderer.image(elements:board.elements,size:CGSize(width:800,height:560),paper:true).representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("\(id)-\(i).png"))}
                }
            }
            for (id,prompt) in [
                ("rocket-live","Build a simplified 3D rocket cutaway LIVE with build_3d_step. Use several successive construction calls, adding real internal fuel and oxidizer tanks, a payload, an engine, nozzle, then shell and fins. Build inside out, keep the inside visible, and finish complete=true. Use arbitrary actual components, not the airplane preset. Use at least three separate construction calls and concise narration for each."),
                ("astronaut-live","Build a simplified 3D astronaut suit teaching model LIVE in successive build_3d_step calls. Include internal pressure layer and cooling system, torso and limbs, helmet with a translucent visor, and a separate oxygen/life-support backpack. Label meaningful parts. Start with inner layers and finish with the exterior while keeping the inside visible. At least three separate calls, each narrating newly added components; complete=true on the final step. Do not use an airplane.")
            ]{
                if args.contains("--photo-case"){break}
                await check("LIVE fresh incremental 3D case: \(id)"){
                    let scene=try await liveSpatial(api:api,prompt:prompt,requireIncremental:true)
                    try expect(scene.parts.filter{$0.layer == "interior"}.count>=2,"No actual internal geometry")
                    try expect(scene.parts.contains{$0.layer == "shell"},"No cutaway shell")
                    try JSONEncoder().encode(scene).write(to:out.appendingPathComponent(id+".json"));try renderSpatial(scene,to:out.appendingPathComponent(id+".png"))
                }
            }
        }
        if args.contains("--live") {
            let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/live-2d")
            try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let credentialFile=args.firstIndex(of:"--key-file").flatMap{i in args.count>i+1 ? args[i+1]:nil}
            let key=credentialFile.flatMap{try? KeyStore.readDotEnv(at:URL(fileURLWithPath:$0))} ?? KeyStore.load()
            if let key {
                let api=OpenAIClient(key:key)
                for (id,prompt) in [
                    ("triangle-sync","Teach the Pythagorean theorem. Start by saying 'Imagine a right triangle' while drawing that triangle with a path. In the next spoken beat add side labels 3 and 4, then explain and draw a²+b²=c² and conclude c=5. Use correctly synchronized narration beats and a clear sketch board."),
                    ("tensor","Draw a board showing the 2 by 4 tensor [[18,47,56,57],[58,1,15,47]]. Include zero-based row and column indices, highlight x[1,2]=15 in blue, explain the shape and show x+1. Use a clear roomy layout like a teacher's sketch."),
                    ("chain-rule","Open a board and explain the derivative of ln(3x²-1). Draw the operations as boxes with arrows and clearly show the two derivatives and the chain rule result."),
                    ("research","Search nasa.gov for how the James Webb Space Telescope sunshield works, then draw a 2D explanatory board about its five layers, hot side and cold side. Include the source link in your summary.")
                ] {
                    await check("LIVE Sol drawing: \(id)") {
                        let (scene,searched)=try await liveDrawing(api:api,prompt:prompt)
                        try expect(!scene.boards.isEmpty,"Sol did not open a drawing board")
                        try expect(scene.boards[0].elements.count>4,"Diagram too sparse")
                        if id=="research" {try expect(searched,"Model did not actually look up the requested information");try expect(scene.summary.contains("http"),"Source URL missing")}
                        try JSONEncoder().encode(scene).write(to:output.appendingPathComponent("\(id).json"))
                        for (i,b) in scene.boards.enumerated() {
                            try SVGExporter.export(b).write(to:output.appendingPathComponent("\(id)-\(i).svg"),atomically:true,encoding:.utf8)
                            try DrawingRenderer.image(elements:b.elements,size:CGSize(width:800,height:560),paper:true).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(id)-\(i).png"))
                        }
                    }
                }
                await check("LIVE spoken reply is decodable audio") {
                    let data=try await api.speech("The board is ready. Two rows and four columns make a tensor with eight values.")
                    let player=try AVAudioPlayer(data:data)
                    try expect(player.duration>1,"Speech audio too short")
                    try data.write(to:output.appendingPathComponent("speech.mp3"))
                }
            }else{await check("LIVE credentials"){throw CheckFailure(description:"No key in Keychain. Import using --import-key-from.")}}
        }
        if args.contains("--live-3d") {
            let credentialFile=args.firstIndex(of:"--key-file").flatMap{i in args.count>i+1 ? args[i+1]:nil}
            let key=credentialFile.flatMap{try? KeyStore.readDotEnv(at:URL(fileURLWithPath:$0))} ?? KeyStore.load()
            if let key {
                let api=OpenAIClient(key:key),output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/live-3d")
                try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                for (id,prompt) in [("aircraft","Build an interactive 3D airplane and explain the four forces on it. Use the airplane geometry and clear lift, weight, thrust and drag arrows with labels, like a teaching model that floats over my desktop."),
                                    ("water","Build a real interactive 3D model of a water molecule, with one oxygen atom, two hydrogen atoms and two bonds. Use meaningful named parts, different atom colors and labels. Explain its bent shape. Build each part in narrated stages."),
                                    ("motor","Build a 3D cutaway electric motor live, showing its shaft, rotor, stator, copper coils, bearings and outer housing. Use actual separate internal components, mark interior and shell layers, and showInterior true. Build from the inside out in narrated stages. Use a translucent housing and sparse labels. This is a simplified educational assembly.")] {
                    await check("LIVE Sol 3D: \(id)") {
                        let model=try await liveSpatial(api:api,prompt:prompt)
                        if id=="aircraft"{try expect(model.parts.contains{$0.kind=="airplane"},"No aircraft geometry");try expect(model.parts.filter{$0.kind=="arrow"}.count>=4,"Missing force arrows")}
                        else if id=="water"{try expect(model.parts.filter{$0.kind=="sphere"}.count>=3,"No molecular atom geometry");try expect(!model.parts.contains{$0.kind=="airplane"},"Unrelated preset used")}
                        else{try expect(model.parts.filter{$0.layer == "interior"}.count>=3,"Motor lacks real internal parts");try expect(model.parts.contains{$0.layer == "shell"},"Motor has no cutaway housing");try expect(model.showInterior==true,"Interior is not exposed")}
                        try expect((model.beats?.count ?? 0)>=3,"3D model has no staged construction")
                        try JSONEncoder().encode(model).write(to:output.appendingPathComponent(id+".json"))
                        try renderSpatial(model,to:output.appendingPathComponent(id+".png"))
                    }
                }
            }else{await check("LIVE 3D credentials"){throw CheckFailure(description:"No authorized API key")}}
        }
        print("\(passed) passed, \(failures) failed")
        exit(failures==0 ? 0:1)
    }

    @MainActor static func renderSpatial(_ definition:SpatialScene,to file:URL) throws {
        guard let device=MTLCreateSystemDefaultDevice() else{throw CheckFailure(description:"No Metal device")}
        let renderer=SCNRenderer(device:device,options:nil),scene=SpatialBuilder.build(definition)
        scene.background.contents=DrawingPalette.paper;renderer.scene=scene
        renderer.pointOfView=scene.rootNode.childNode(withName:"camera",recursively:false)
        let image=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:760),antialiasingMode:.multisampling4X)
        guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else{throw CheckFailure(description:"3D snapshot failed")}
        try png.write(to:file)
    }
    static func liveSpatial(api:OpenAIClient,prompt:String,requireIncremental:Bool=false) async throws ->SpatialScene {
        var input:[[String:Any]]=[["role":"user","content":prompt]],scene:SpatialScene?,steps=0,complete=false
        for round in 0..<18 {
            print("  3D agent round \(round+1)");fflush(stdout)
            let response=try await api.respond(input:input)
            let output=response["output"] as? [[String:Any]] ?? [];input.append(contentsOf:output)
            let calls=output.filter{$0["type"] as? String=="function_call"}
            if calls.isEmpty {
                if let scene{
                    if requireIncremental{try expect(steps>=3 && complete,"Agent did not complete a real incremental construction")}
                    return scene
                }
                throw CheckFailure(description:"No 3D model: \(OpenAIClient.outputText(response))")
            }
            for call in calls {
                var result=""
                do {
                    if call["name"] as? String == "build_3d_step"{
                        let step=try JSONDecoder().decode(SpatialBuildStep.self,from:Data((call["arguments"] as! String).utf8))
                        scene=try step.appending(to:scene);steps+=1;complete=step.complete
                        result=complete ? "Final parts are building. Finish briefly, do not repeat.":"Parts added live. Continue build_3d_step with only NEW parts, reset=false. Set complete=true on the final step."
                        print("  Incremental step \(steps): \(step.parts.map(\.name).joined(separator:", ")); complete=\(complete)")
                    }else{
                        guard !requireIncremental,call["name"] as? String=="show_3d" else{throw CheckFailure(description:"Use build_3d_step to construct this model live in several calls")}
                        scene=try JSONDecoder().decode(SpatialScene.self,from:Data((call["arguments"] as! String).utf8)).validated();result="Success. Real 3D geometry rendered. Finish briefly."
                    }
                }catch{result="Tool failed: \(error.localizedDescription). Correct and retry.";print("  \(result)")}
                input.append(["type":"function_call_output","call_id":call["call_id"] as! String,"output":result])
            }
        }
        throw CheckFailure(description:"3D agent exceeded eighteen rounds")
    }
    static func liveDrawing(api:OpenAIClient,prompt:String) async throws ->(DrawScene,Bool) {
        var input:[[String:Any]]=[["role":"user","content":prompt]],scene:DrawScene?,searched=false
        for round in 0..<6 {
            print("  Live agent round \(round+1)");fflush(stdout)
            let response=try await api.respond(input:input)
            let output=response["output"] as? [[String:Any]] ?? []
            if output.contains(where:{$0["type"] as? String=="web_search_call"}){searched=true}
            input.append(contentsOf:output)
            let calls=output.filter{$0["type"] as? String=="function_call"}
            if calls.isEmpty {
                guard let scene else{throw CheckFailure(description:"No scene: \(OpenAIClient.outputText(response))")}
                return(scene,searched)
            }
            for call in calls {
                print("  Tool: \(call["name"] as? String ?? "unknown")");fflush(stdout)
                var result=""
                var images:[BoardImage]=[]
                do {
                    if call["name"] as? String == "find_images"{
                        let args=try JSONSerialization.jsonObject(with:Data((call["arguments"] as! String).utf8)) as? [String:String] ?? [:]
                        images=try await BoardImages.search(query:args["query"] ?? "",source:args["source"] ?? "auto")
                        result=String(data:try JSONEncoder().encode(images),encoding:.utf8)!+"\nUse an appropriate returned photo now in draw_scene, then finish. Do not keep searching for a perfect pose. A representative photo alongside a vector diagram is enough."
                        print("  Images: \(images.count), query: \(args["query"] ?? "")")
                    }else{
                    guard call["name"] as? String=="draw_scene" else{throw CheckFailure(description:"No screen is attached in this test")}
                    let next=try JSONDecoder().decode(DrawScene.self,from:Data((call["arguments"] as! String).utf8)).validated()
                    scene=next;result="Success. Drawing rendered. Finish briefly."
                    }
                }catch{result="Tool failed: \(error.localizedDescription). Correct and retry.";print("  \(result)");fflush(stdout)}
                input.append(["type":"function_call_output","call_id":call["call_id"] as! String,"output":result])
                if !images.isEmpty{input.append(["role":"user","content":BoardImages.content(images)])}
            }
        }
        throw CheckFailure(description:"Agent exceeded six rounds")
    }
}

private extension Data {
    init(reading stream:InputStream) {
        self.init();stream.open();defer{stream.close()}
        let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:4096);defer{buffer.deallocate()}
        while stream.hasBytesAvailable{let n=stream.read(buffer,maxLength:4096);if n<=0{break};append(buffer,count:n)}
    }
}
