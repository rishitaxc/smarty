import AppKit
import SwiftUI
import SceneKit
import UniformTypeIdentifiers
import SideCore

@MainActor final class SpatialDocument:ObservableObject {
    @Published var definition:SpatialScene
    @Published var scene:SCNScene
    @Published var selectedName=""
    @Published var selectedDetail=""
    @Published var rotating=false
    @Published var labels=true
    @Published var inside=false
    @Published var spread=false
    @Published var building=false
    @Published var planning=false
    @Published var liveBuild=false
    @Published var caption=""
    @Published var addedCount=0
    @Published var step=0
    @Published var focusedKey:String?
    var totalSteps=0
    weak var view:InteractiveSceneView?
    weak var highlighted:SCNNode?
    var originalMaterials:[SCNMaterial]=[]
    var components:[PartNode]=[]
    var modelBounds:(min:SCNVector3,max:SCNVector3)=(SCNVector3(-1,-1,-1),SCNVector3(1,1,1))
    var originals:[String:(position:SCNVector3,scale:SCNVector3,opacity:CGFloat)]=[:]
    var revealed=Set<String>()
    var onAsk:((String)->Void)?
    var onReplay:(()->Void)?
    init(_ definition:SpatialScene){self.definition=definition;scene=SpatialBuilder.build(definition);prepare()}
    func prepare(){
        modelBounds=scene.rootNode.childNode(withName:"content",recursively:false)!.boundingBox
        components=SpatialBuilder.components(in:scene);originals=[:]
        for n in components{originals[n.componentKey]=(n.position,n.scale,n.opacity)}
        revealed=Set(components.map(\.componentKey));addedCount=components.count
        inside=definition.showInterior ?? false;applyAppearance()
    }
    func update(_ next:SpatialScene){
        definition=next;scene=SpatialBuilder.build(next)
        selectedName="";selectedDetail="";highlighted=nil;originalMaterials=[]
        rotating=false;labels=true;spread=false;planning=false;caption="";building=false;focusedKey=nil;prepare()
    }
    func reset(){
        rotating=false;scene.rootNode.childNode(withName:"content",recursively:false)?.removeAction(forKey:"spin")
        scene.rootNode.childNode(withName:"content",recursively:false)?.eulerAngles=SCNVector3Zero
        spread=false;focusedKey=nil;applyAppearance();view?.extraSpace=false;view?.frameModel()
    }
    func toggleRotation(){
        rotating.toggle()
        let content=scene.rootNode.childNode(withName:"content",recursively:false)
        if rotating{content?.runAction(.repeatForever(.rotateBy(x:0,y:2*CGFloat.pi,z:0,duration:24)),forKey:"spin")}
        else{content?.removeAction(forKey:"spin")}
    }
    func toggleLabels(){labels.toggle();applyAppearance()}
    func toggleInside(){inside.toggle();focusedKey=nil;applyAppearance()}
    func toggleSpread(){spread.toggle();focusedKey=nil;applyAppearance();view?.extraSpace=spread;view?.frameModel()}
    func focusSelection(){
        guard let part=components.first(where:{$0.partName == selectedName}) else{return}
        rotating=false;scene.rootNode.childNode(withName:"content",recursively:false)?.removeAction(forKey:"spin")
        focusedKey=part.componentKey;applyAppearance();view?.focus(on:part)
    }
    func targetPosition(_ node:PartNode)->SCNVector3{
        let p=originals[node.componentKey]?.position ?? node.position
        guard spread,node.layer != "annotation",!(node.geometry is SCNPlane) else{return p}
        let length=sqrt(p.x*p.x+p.y*p.y+p.z*p.z)
        if length<0.2{return SCNVector3(p.x+(node.layer == "interior" ? -1.1:1.4),p.y,p.z)}
        return SCNVector3(p.x+p.x/length*1.5,p.y+p.y/length*1.5,p.z+p.z/length*1.5)
    }
    func applyAppearance(){
        for n in components{
            n.isHidden = !revealed.contains(n.componentKey) || (focusedKey != nil && focusedKey != n.componentKey) || (!labels && (n.childNodes.first?.geometry is SCNPlane || n.geometry is SCNPlane))
            n.opacity=(originals[n.componentKey]?.opacity ?? 1)*(inside && n.layer == "shell" ? 0.11:1)
            n.position=targetPosition(n)
            n.renderingOrder=inside && n.layer == "shell" ? 20:0
            if n.layer == "shell"{
                func depth(_ geometry:SCNGeometry?){geometry?.materials=geometry?.materials.map{m in let copy=m.copy() as! SCNMaterial;copy.writesToDepthBuffer = !inside;return copy} ?? []}
                depth(n.geometry);for child in n.childNodes{depth(child.geometry)}
            }
        }
    }
    func beginConstruction(){
        rotating=false;spread=false;scene.rootNode.childNode(withName:"content",recursively:false)?.removeAction(forKey:"spin")
        scene.rootNode.childNode(withName:"content",recursively:false)?.eulerAngles=SCNVector3Zero
        revealed=[];addedCount=0;step=0;totalSteps=definition.constructionBeats.count;building=true;planning=false;caption="Preparing the first parts"
        applyAppearance();view?.frameModel()
    }
    func reserveBounds(_ low:Vector3,_ high:Vector3){
        modelBounds=(SCNVector3(low.x,low.y,low.z),SCNVector3(high.x,high.y,high.z))
        view?.modelBounds=modelBounds;view?.frameModel()
    }
    func append(_ next:SpatialScene,newParts:[SpatialPart]){
        guard let content=scene.rootNode.childNode(withName:"content",recursively:false) else{return}
        for part in newParts{
            let node=SpatialBuilder.node(part);content.addChildNode(node)
        }
        let all=SpatialBuilder.components(in:scene),known=Set(components.map(\.componentKey))
        for n in all where !known.contains(n.componentKey){originals[n.componentKey]=(n.position,n.scale,n.opacity);n.isHidden=true;components.append(n)}
        definition=next;applyAppearance()
    }
    func reveal(_ names:[String],duration:Double) async {
        let next=components.filter{n in !revealed.contains(n.componentKey) && names.contains{n.componentKey == $0 || n.componentKey.hasPrefix($0+"/")}}
        guard !next.isEmpty else{return}
        let interval=max(0.035,duration/Double(next.count))
        for n in next{
            guard !Task.isCancelled else{return}
            revealed.insert(n.componentKey);n.isHidden = !labels && n.childNodes.first?.geometry is SCNPlane
            let target=targetPosition(n),scale=originals[n.componentKey]!.scale
            n.opacity=0;n.position=SCNVector3(target.x,target.y+0.18,target.z);n.scale=SCNVector3(scale.x*0.88,scale.y*0.88,scale.z*0.88)
            SCNTransaction.begin();SCNTransaction.animationDuration=min(0.45,interval*0.85)
            SCNTransaction.animationTimingFunction=CAMediaTimingFunction(name:.easeOut)
            n.opacity=originals[n.componentKey]!.opacity*(inside && n.layer == "shell" ? 0.11:1)
            n.position=target;n.scale=scale;SCNTransaction.commit();addedCount=revealed.count
            do{try await Task.sleep(for:.seconds(interval))}catch{return}
        }
    }
    func finishConstruction(){
        building=false;liveBuild=false;caption="";revealed=Set(components.map(\.componentKey));addedCount=components.count
        for n in components{n.removeAllAnimations();n.scale=originals[n.componentKey]!.scale}
        applyAppearance()
    }
    func select(_ hit:SCNNode?){
        focusedKey=nil;applyAppearance()
        if let highlighted,!originalMaterials.isEmpty{highlighted.geometry?.materials=originalMaterials}
        highlighted=nil;originalMaterials=[]
        guard let hit else{selectedName="";selectedDetail="";return}
        var part:SCNNode?=hit
        while part != nil && !(part is PartNode){part=part?.parent}
        guard let part=part as? PartNode else{return}
        selectedName=part.partName;selectedDetail=part.partDetail
        if part.layer == "interior",!inside{inside=true;applyAppearance()}
        let visible=hit.geometry != nil ? hit:part.childNodes.first ?? part
        if let materials=visible.geometry?.materials{
            originalMaterials=materials;highlighted=visible
            visible.geometry?.materials=materials.map{m in let copy=m.copy() as! SCNMaterial;copy.emission.contents=NSColor(srgbRed:0.22,green:0.18,blue:0.04,alpha:1);return copy}
        }
    }
    func save(){
        let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"scn") ?? .data];panel.nameFieldStringValue=definition.title+".scn"
        if panel.runModal() == .OK,let url=panel.url{
            if !SpatialBuilder.build(definition).write(to:url,options:nil,delegate:nil,progressHandler:nil){NSAlert(error:SideAPIError("The 3D model could not be saved at that location.")).runModal()}
        }
    }
}

final class InteractiveSceneView:SCNView {
    var onSelect:((SCNNode?)->Void)?
    private var down:NSPoint = .zero
    private var previous:NSPoint = .zero
    private var orbit:SpatialOrbit?
    private var didFrame=false
    private var fittedSize:NSSize = .zero
    var ignoreShells=false
    var modelBounds:(min:SCNVector3,max:SCNVector3)=(SCNVector3(-1,-1,-1),SCNVector3(1,1,1))
    var extraSpace=false
    override var isOpaque:Bool{false}
    override var mouseDownCanMoveWindow:Bool{false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    override func layout(){super.layout();if (!didFrame || fittedSize != bounds.size),bounds.width>0,bounds.height>0{frameModel()}}
    func frameModel(){
        guard scene != nil,bounds.height>0 else{return}
        let b=modelBounds,padding:Double=extraSpace ? 2:0
        orbit=SpatialOrbit(min:Vector3(Double(b.min.x)-padding,Double(b.min.y)-padding,Double(b.min.z)-padding),max:Vector3(Double(b.max.x)+padding,Double(b.max.y)+padding,Double(b.max.z)+padding),aspect:Double(bounds.width/bounds.height))
        didFrame=true;fittedSize=bounds.size;applyCamera()
    }
    func modelChanged(){didFrame=false;frameModel()}
    func focus(on node:SCNNode){
        guard let root=scene?.rootNode else{return}
        let b=node.boundingBox
        var points:[SCNVector3]=[]
        for x in [b.min.x,b.max.x]{for y in [b.min.y,b.max.y]{for z in [b.min.z,b.max.z]{points.append(node.convertPosition(SCNVector3(x,y,z),to:root))}}}
        guard !points.isEmpty else{return}
        let low=Vector3(Double(points.map(\.x).min()!),Double(points.map(\.y).min()!),Double(points.map(\.z).min()!))
        let high=Vector3(Double(points.map(\.x).max()!),Double(points.map(\.y).max()!),Double(points.map(\.z).max()!))
        orbit=SpatialOrbit(min:low,max:high,aspect:Double(bounds.width/max(1,bounds.height)));applyCamera()
    }
    private func applyCamera(){
        guard let orbit,let camera=pointOfView else{return}
        let p=orbit.position,t=orbit.target
        SCNTransaction.begin();SCNTransaction.disableActions=true
        camera.position=SCNVector3(p.x,p.y,p.z);camera.look(at:SCNVector3(t.x,t.y,t.z));SCNTransaction.commit();setNeedsDisplay(bounds)
    }
    override func mouseDown(with event:NSEvent){down=convert(event.locationInWindow,from:nil);previous=down}
    override func mouseDragged(with event:NSEvent){
        let p=convert(event.locationInWindow,from:nil);orbit?.rotate(dx:Double(p.x-previous.x),dy:Double(p.y-previous.y));previous=p;applyCamera()
    }
    override func mouseUp(with event:NSEvent){
        let p=convert(event.locationInWindow,from:nil)
        if hypot(p.x-down.x,p.y-down.y)<4{
            let hits=hitTest(p,options:[.sortResults:true]).filter{hit in
                var n:SCNNode?=hit.node
                while let node=n{if let part=node as? PartNode{return !(ignoreShells && part.layer == "shell")};n=node.parent}
                return true
            }
            onSelect?(hits.first?.node)
        }
    }
    override func scrollWheel(with event:NSEvent){
        let delta=Double(-event.scrollingDeltaY)*(event.hasPreciseScrollingDeltas ? 0.003:0.008)
        orbit?.zoom(delta:max(-0.18,min(0.18,delta)));applyCamera()
    }
    override func magnify(with event:NSEvent){orbit?.zoom(delta:Double(-event.magnification)*2);applyCamera()}
}

struct SpatialCanvas:NSViewRepresentable {
    @ObservedObject var document:SpatialDocument
    func makeNSView(context:Context)->InteractiveSceneView {
        let v=InteractiveSceneView();v.backgroundColor = .clear;v.allowsCameraControl=false
        v.antialiasingMode = .multisampling4X;v.preferredFramesPerSecond=60;v.isPlaying=true
        v.setAccessibilityLabel("Interactive 3D model. Drag to orbit, scroll to zoom, or click a part.")
        v.onSelect={node in document.select(node)};document.view=v;return v
    }
    func updateNSView(_ view:InteractiveSceneView,context:Context){
        view.ignoreShells=document.inside
        if view.scene !== document.scene{view.modelBounds=document.modelBounds;view.extraSpace=document.spread;view.scene=document.scene;view.pointOfView=document.scene.rootNode.childNode(withName:"camera",recursively:false);view.modelChanged()}
        view.rendersContinuously=document.rotating || document.building
    }
}

struct SpatialRoot:View {
    @ObservedObject var document:SpatialDocument
    let close:()->Void
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:23).fill(Color(red:0.07,green:0.095,blue:0.12).opacity(0.97))
            SpatialCanvas(document:document).clipShape(RoundedRectangle(cornerRadius:23))
            VStack(spacing:10){
                HStack(spacing:12){
                    Image(systemName:"cube.transparent").foregroundStyle(.secondary)
                    Text(document.definition.title).font(.system(size:12,weight:.medium)).lineLimit(1)
                    Spacer()
                    Menu{ForEach(document.components,id:\.componentKey){part in Button(part.partName){document.select(part)}}}label:{Image(systemName:"list.bullet")}.help("Inspect every part").accessibilityLabel("Model parts")
                    Button{document.onReplay?()}label:{Image(systemName:"play.circle")}.help("Build again with narration").accessibilityLabel("Replay 3D construction")
                    Button{document.save()}label:{Image(systemName:"square.and.arrow.up")}.help("Save 3D model").accessibilityLabel("Save 3D model")
                    Button(action:close){Image(systemName:"xmark")}.help("Close model").accessibilityLabel("Close 3D model")
                }.padding(.horizontal,16).padding(.vertical,12).background(.regularMaterial,in:Capsule())
                if document.planning{HStack(spacing:9){ProgressView().controlSize(.small);Text("Planning the parts and their assembly…").font(.system(size:12))}.padding(15)}
                Spacer()
                if !document.selectedName.isEmpty {
                    HStack(alignment:.top,spacing:14){
                        VStack(alignment:.leading,spacing:5){
                            Text(document.selectedName).font(.system(size:13,weight:.semibold))
                            if !document.selectedDetail.isEmpty{Text(document.selectedDetail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                        }
                        Spacer(minLength:0)
                        Button("Focus"){document.focusSelection()}.font(.system(size:11,weight:.medium)).accessibilityLabel("Focus selected part")
                        Button("Ask Side"){document.onAsk?(document.selectedName)}.font(.system(size:11,weight:.medium))
                    }.padding(15).background(.regularMaterial,in:RoundedRectangle(cornerRadius:15)).frame(maxWidth:500)
                }
                if document.building{
                    VStack(alignment:.leading,spacing:7){
                        HStack{Text(document.liveBuild ? "Building live · Step \(document.step)":"Building · Step \(document.step) of \(document.totalSteps)");Spacer();Text(document.liveBuild ? "\(document.addedCount) parts built":"\(document.addedCount) / \(document.components.count) parts")}.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                        Text(document.caption).font(.system(size:12)).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
                        ProgressView(value:Double(document.addedCount),total:Double(max(1,document.components.count))).tint(Color(red:0.75,green:0.81,blue:0.59))
                    }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:15))
                }
                HStack(spacing:14){
                    Text("Drag to orbit · Scroll to zoom").font(.system(size:10)).foregroundStyle(.secondary);Spacer(minLength:0)
                    Button{document.toggleInside()}label:{Label("Inside",systemImage:document.inside ? "cube.transparent.fill":"cube.transparent")}.foregroundStyle(document.inside ? Color.yellow:Color.primary).accessibilityLabel("Show model interior")
                    Button{document.toggleSpread()}label:{Image(systemName:document.spread ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right")}.help("Spread parts apart").accessibilityLabel("Spread model parts")
                    Button{document.toggleRotation()}label:{Image(systemName:document.rotating ? "pause":"rotate.3d")}.help("Rotate model").accessibilityLabel("Rotate 3D model")
                    Button{document.toggleLabels()}label:{Image(systemName:document.labels ? "tag":"tag.slash")}.help("Show or hide labels").accessibilityLabel("Toggle 3D labels")
                    Button{document.reset()}label:{Image(systemName:"arrow.counterclockwise")}.help("Reset view").accessibilityLabel("Reset 3D view")
                }.font(.system(size:11)).padding(.horizontal,16).padding(.vertical,12).background(.regularMaterial,in:Capsule())
            }.padding(13)
        }.overlay(RoundedRectangle(cornerRadius:23).strokeBorder(.white.opacity(0.12),lineWidth:1))
            .buttonStyle(.borderless).preferredColorScheme(.dark).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

@MainActor final class SpatialWindowController:NSWindowController,NSWindowDelegate {
    let spatialDocument:SpatialDocument
    var onClose:(()->Void)?
    init(definition:SpatialScene,screen:NSScreen){
        spatialDocument=SpatialDocument(definition)
        let frame=screen.visibleFrame,w=min(780,frame.width*0.49),h=min(790,frame.height-115)
        let window=NotchPanel(contentRect:NSRect(x:frame.minX+20,y:frame.midY-h/2-20,width:w,height:h),styleMask:[.borderless,.nonactivatingPanel,.resizable],backing:.buffered,defer:false)
        window.title="Side 3D · \(definition.title)";window.backgroundColor = .clear;window.isOpaque=false
        window.hasShadow=true;window.isReleasedWhenClosed=false;window.hidesOnDeactivate=false
        window.level = .floating;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        window.isMovableByWindowBackground=true;window.minSize=NSSize(width:560,height:500)
        super.init(window:window);window.delegate=self
        let host=NSHostingView(rootView:SpatialRoot(document:spatialDocument,close:{[weak self] in self?.close()}));host.sizingOptions=[];window.contentView=host
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func present(_ definition:SpatialScene){
        if definition != spatialDocument.definition{spatialDocument.update(definition)}
        window?.title="Side 3D · \(definition.title)";spatialDocument.view?.isPlaying=true
        NSApp.activate(ignoringOtherApps:true);showWindow(nil);window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification:Notification){
        spatialDocument.view?.isPlaying=false;spatialDocument.view?.rendersContinuously=false
        spatialDocument.rotating=false;spatialDocument.scene.rootNode.childNode(withName:"content",recursively:false)?.removeAction(forKey:"spin")
        DispatchQueue.main.async{[weak self] in self?.onClose?()}
    }
}
