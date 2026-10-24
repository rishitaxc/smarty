import Foundation
import AppKit
import SceneKit
import simd

public struct Vector3:Codable,Equatable,Sendable {
    public var x:Double;public var y:Double;public var z:Double
    public init(_ x:Double,_ y:Double,_ z:Double){self.x=x;self.y=y;self.z=z}
    var scn:SCNVector3 {SCNVector3(x,y,z)}
    var simd:SIMD3<Float>{SIMD3(Float(x),Float(y),Float(z))}
}
public final class PartNode:SCNNode {
    public var partName=""
    public var partDetail=""
    public var componentKey=""
    public var layer="structure"
    public override init(){super.init()}
    public required init?(coder:NSCoder){super.init(coder:coder)}
    public override var classForCoder:AnyClass{SCNNode.self}
}
public struct SpatialPart:Codable,Equatable,Sendable {
    public var name:String
    public var kind:String
    public var position:Vector3
    public var rotation:Vector3
    public var size:Vector3
    public var color:String
    public var opacity:Double
    public var label:String
    public var detail:String
    public var vertices:[Vector3]
    public var triangles:[Int]
    public var layer:String?
    public init(name:String,kind:String,position:Vector3=Vector3(0,0,0),rotation:Vector3=Vector3(0,0,0),
                size:Vector3=Vector3(1,1,1),color:String="blue",opacity:Double=1,label:String="",detail:String="",
                vertices:[Vector3]=[],triangles:[Int]=[],layer:String="structure") {
        self.name=name;self.kind=kind;self.position=position;self.rotation=rotation;self.size=size
        self.color=color;self.opacity=opacity;self.label=label;self.detail=detail;self.vertices=vertices;self.triangles=triangles;self.layer=layer
    }
}
public struct SpatialBeat:Codable,Equatable,Sendable {
    public var narration:String
    public var parts:[String]
    public var interior:Bool
    public init(narration:String,parts:[String],interior:Bool=false){self.narration=narration;self.parts=parts;self.interior=interior}
}
public struct SpatialScene:Codable,Equatable,Sendable {
    public var id:String
    public var title:String
    public var summary:String
    public var narration:String
    public var parts:[SpatialPart]
    public var beats:[SpatialBeat]?
    public var showInterior:Bool?
    public init(id:String="spatial",title:String,summary:String,narration:String,parts:[SpatialPart],beats:[SpatialBeat]=[],showInterior:Bool=false) {
        self.id=id;self.title=title;self.summary=summary;self.narration=narration;self.parts=parts;self.beats=beats;self.showInterior=showInterior
    }
    public func validated() throws ->SpatialScene {
        guard !id.isEmpty,title.count<=160,summary.count<=12000,narration.count<=8000,
              !parts.isEmpty,parts.count<=140 else{throw SideAPIError("The 3D scene is empty or too large.")}
        var names=Set<String>()
        for p in parts {
            guard !p.name.isEmpty,names.insert(p.name).inserted,p.name.count<=120,
                  ["box","sphere","cylinder","cone","torus","arrow","label","mesh","airplane"].contains(p.kind)
            else{throw SideAPIError("Every 3D part needs a unique name and a supported geometry.")}
            guard ["structure","shell","interior","annotation"].contains(p.layer ?? "structure") else{throw SideAPIError("A 3D part has an unknown layer.")}
            let values=[p.position.x,p.position.y,p.position.z,p.rotation.x,p.rotation.y,p.rotation.z,
                        p.size.x,p.size.y,p.size.z,p.opacity]+p.vertices.flatMap{[$0.x,$0.y,$0.z]}
            guard values.allSatisfy(\.isFinite),(0...1).contains(p.opacity),p.label.count<=160,p.detail.count<=1500,
                  [p.position.x,p.position.y,p.position.z].allSatisfy({abs($0)<=50}),
                  [p.rotation.x,p.rotation.y,p.rotation.z].allSatisfy({abs($0)<=360}),
                  [p.size.x,p.size.y,p.size.z].allSatisfy({abs($0)<=40})
            else{throw SideAPIError("The 3D scene contains invalid dimensions or positions.")}
            if p.kind != "arrow" && p.kind != "mesh" {
                guard min(p.size.x,p.size.y,p.size.z)>0 else{throw SideAPIError("3D primitive dimensions must be positive.")}
            }
            if p.kind == "arrow" {guard simd_length(p.size.simd)>0.05 else{throw SideAPIError("A 3D arrow needs a nonzero direction vector.")}}
            if p.kind == "mesh" {
                guard p.vertices.count>=3,p.vertices.count<=4000,!p.triangles.isEmpty,p.triangles.count<=18000,
                      p.triangles.count%3==0,p.triangles.allSatisfy({p.vertices.indices.contains($0)}),
                      p.vertices.allSatisfy({max(abs($0.x),abs($0.y),abs($0.z))<=40})
                else{throw SideAPIError("The 3D mesh has invalid triangle indices or vertices.")}
            }
        }
        if let beats,!beats.isEmpty {
            guard beats.count<=16 else{throw SideAPIError("Use at most sixteen 3D construction steps.")}
            let keys=Set(SpatialBuilder.componentKeys(parts)),groups=Set(parts.map(\.name))
            var covered=Set<String>()
            for beat in beats {
                guard !beat.narration.isEmpty,beat.narration.count<=1800,!beat.parts.isEmpty else{throw SideAPIError("Each 3D construction step needs narration and part names.")}
                for key in beat.parts {
                    if keys.contains(key){covered.insert(key)}
                    else if groups.contains(key){covered.formUnion(keys.filter{$0.hasPrefix(key+"/")})}
                    else{throw SideAPIError("Unknown 3D construction part: \(key). Use exact part names.")}
                }
            }
            guard covered==keys else{throw SideAPIError("The construction steps must include every 3D part, including labels and interior parts.")}
        }
        return self
    }
    public var constructionBeats:[SpatialBeat] {
        if let beats,!beats.isEmpty{return beats}
        return parts.map{SpatialBeat(narration:$0.detail.isEmpty ? "Adding \($0.name).":$0.detail,parts:[$0.name],interior:$0.layer == "interior")}
    }
}

public enum SpatialBuilder {
    public static let aircraftComponents=["Cabin floor","Cockpit instruments","Pilot seats","Passenger seats","Cabin frames","Left wing spar","Right wing spar","Left fuel tank","Right fuel tank","Left engine fan","Right engine fan","Left compressor","Right compressor","Left turbine","Right turbine","Fuselage","Nose","Cockpit","Left wing","Left stabilizer","Left engine","Left engine intake","Left engine nozzle","Right wing","Right stabilizer","Right engine","Right engine intake","Right engine nozzle","Vertical stabilizer"]
    public static func componentKeys(_ parts:[SpatialPart])->[String]{parts.flatMap{p in p.kind == "airplane" ? aircraftComponents.map{p.name+"/"+$0}:[p.name]}}
    public static func components(in scene:SCNScene)->[PartNode]{
        var result:[PartNode]=[]
        scene.rootNode.childNode(withName:"content",recursively:false)?.enumerateChildNodes{node,_ in
            if let part=node as? PartNode,!part.componentKey.isEmpty{result.append(part)}
        }
        return result
    }
    public static func material(_ color:String)->SCNMaterial {
        let m=SCNMaterial();m.diffuse.contents=DrawingPalette.color(color)
        m.lightingModel = .physicallyBased;m.metalness.contents=0.14;m.roughness.contents=0.54
        m.isDoubleSided=true;return m
    }
    public static func build(_ definition:SpatialScene)->SCNScene {
        let scene=SCNScene();scene.background.contents=NSColor.clear
        let content=SCNNode();content.name="content"
        scene.rootNode.addChildNode(content)
        for part in definition.parts{content.addChildNode(node(part))}
        let bounds=content.boundingBox
        let center=SCNVector3((bounds.min.x+bounds.max.x)/2,(bounds.min.y+bounds.max.y)/2,(bounds.min.z+bounds.max.z)/2)
        let radius=max(1,max(bounds.max.x-bounds.min.x,bounds.max.y-bounds.min.y,bounds.max.z-bounds.min.z)/2)
        let camera=SCNNode();camera.name="camera";camera.camera=SCNCamera();camera.camera?.fieldOfView=46
        camera.camera?.zNear=0.02;camera.camera?.zFar=500
        camera.position=SCNVector3(center.x+radius*1.65,center.y+radius*1.15,center.z+radius*2.25)
        camera.look(at:center);scene.rootNode.addChildNode(camera)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient
        ambient.light?.intensity=220;ambient.light?.color=NSColor(white:0.96,alpha:1);scene.rootNode.addChildNode(ambient)
        let key=SCNNode();key.light=SCNLight();key.light?.type = .omni;key.light?.intensity=650
        key.position=SCNVector3(center.x-4,center.y+10,center.z+7);scene.rootNode.addChildNode(key)
        let rim=SCNNode();rim.light=SCNLight();rim.light?.type = .omni;rim.light?.intensity=300
        rim.light?.color=NSColor(srgbRed:0.78,green:0.86,blue:1,alpha:1)
        rim.position=SCNVector3(center.x+6,center.y+4,center.z-6);scene.rootNode.addChildNode(rim)
        return scene
    }
    public static func node(_ p:SpatialPart)->SCNNode {
        let node:SCNNode
        switch p.kind {
        case "airplane":node=airplane(color:p.color == "white" ? "#dfe4eb":p.color)
        case "arrow":node=arrow(direction:p.size.simd,color:p.color)
        case "label":node=label(p.label.isEmpty ? p.name:p.label,color:p.color,width:p.size.x,height:p.size.y)
        case "mesh":
            let vertices=p.vertices.map(\.scn)
            var normals=[SIMD3<Float>](repeating:.zero,count:vertices.count)
            for i in stride(from:0,to:p.triangles.count,by:3) {
                let a=p.triangles[i],b=p.triangles[i+1],c=p.triangles[i+2]
                let n=simd_cross(p.vertices[b].simd-p.vertices[a].simd,p.vertices[c].simd-p.vertices[a].simd)
                normals[a]+=n;normals[b]+=n;normals[c]+=n
            }
            let normalSource=SCNGeometrySource(normals:normals.map{let n=simd_length($0)>0 ? simd_normalize($0):SIMD3<Float>(0,1,0);return SCNVector3(n.x,n.y,n.z)})
            let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),normalSource],
                elements:[SCNGeometryElement(indices:p.triangles.map{Int32($0)},primitiveType:.triangles)])
            geometry.materials=[material(p.color)];node=SCNNode(geometry:geometry)
        default:
            let g:SCNGeometry
            switch p.kind {
            case "sphere":g=SCNSphere(radius:0.5)
            case "cylinder":g=SCNCylinder(radius:0.5,height:1)
            case "cone":g=SCNCone(topRadius:0,bottomRadius:0.5,height:1)
            case "torus":g=SCNTorus(ringRadius:0.5,pipeRadius:0.1)
            default:g=SCNBox(width:1,height:1,length:1,chamferRadius:0.04)
            }
            g.materials=[material(p.color)];node=SCNNode(geometry:g)
        }
        let part=PartNode();part.addChildNode(node);part.name=p.name;part.position=p.position.scn
        part.eulerAngles=SCNVector3(p.rotation.x*Double.pi/180,p.rotation.y*Double.pi/180,p.rotation.z*Double.pi/180)
        if !["arrow","label","mesh"].contains(p.kind){part.scale=p.size.scn}
        part.opacity=p.opacity;part.partName=p.name;part.partDetail=p.detail;part.layer=p.layer ?? "structure"
        if p.kind == "airplane" {
            node.enumerateChildNodes{child,_ in if let component=child as? PartNode{component.componentKey=p.name+"/"+component.partName}}
        }else{part.componentKey=p.name}
        return part
    }
    static func arrow(direction:SIMD3<Float>,color:String)->SCNNode {
        let node=SCNNode(),length=simd_length(direction),unit=simd_normalize(direction)
        let head=min(0.45,length*0.25),rotation=simd_quatf(from:SIMD3<Float>(0,1,0),to:unit)
        let shaft=SCNNode(geometry:SCNCylinder(radius:0.04,height:CGFloat(length-head)))
        shaft.geometry?.materials=[material(color)];shaft.simdPosition=unit*(length-head)/2;shaft.simdOrientation=rotation
        let tip=SCNNode(geometry:SCNCone(topRadius:0,bottomRadius:0.14,height:CGFloat(head)))
        tip.geometry?.materials=[material(color)];tip.simdPosition=unit*(length-head/2);tip.simdOrientation=rotation
        node.addChildNode(shaft);node.addChildNode(tip);return node
    }
    static func label(_ text:String,color:String,width:Double,height:Double)->SCNNode {
        let imageWidth=max(100,min(1600,100*width/height))
        let image=NSImage(size:NSSize(width:imageWidth,height:100));image.lockFocus()
        let r=NSRect(x:2,y:2,width:imageWidth-4,height:96)
        let bg=NSBezierPath(roundedRect:r,xRadius:18,yRadius:18)
        DrawingPalette.paper.withAlphaComponent(0.96).setFill();bg.fill()
        DrawingPalette.color(color).withAlphaComponent(0.4).setStroke();bg.lineWidth=2;bg.stroke()
        let style=NSMutableParagraphStyle();style.alignment = .center;style.lineBreakMode = .byWordWrapping
        let font=TextFitter.font(for:text,preferredSize:60,in:CGSize(width:imageWidth-30,height:80),style:style)
        let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:DrawingPalette.color("ink"),.paragraphStyle:style]
        let measured=(text as NSString).boundingRect(with:NSSize(width:imageWidth-30,height:500),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attrs)
        (text as NSString).draw(in:NSRect(x:15,y:(100-measured.height)/2,width:imageWidth-30,height:measured.height),withAttributes:attrs)
        image.unlockFocus()
        let geometry=SCNPlane(width:width,height:height)
        let m=SCNMaterial();m.diffuse.contents=image;m.lightingModel = .constant;m.isDoubleSided=true
        m.writesToDepthBuffer=false;m.readsFromDepthBuffer=false
        geometry.materials=[m];let node=SCNNode(geometry:geometry)
        node.constraints=[SCNBillboardConstraint()];node.renderingOrder=100;return node
    }
    public static func airplane(color:String="#dfe4eb")->SCNNode {
        let root=SCNNode(),white=material(color),dark=material("#293947")
        func add(_ name:String,_ geometry:SCNGeometry,_ position:SCNVector3,_ detail:String,mat:SCNMaterial?=nil,layer:String="structure")->SCNNode {
            geometry.materials=[mat ?? white];let n=PartNode();n.geometry=geometry;n.name=name;n.position=position
            n.partName=name;n.partDetail=detail;n.layer=layer;root.addChildNode(n);return n
        }
        let interior=material("#8cbbcf"),warm=material("#ceaa67")
        _=add("Cabin floor",SCNBox(width:0.48,height:0.035,length:4.8,chamferRadius:0.01),SCNVector3(0,-0.13,-0.05),"The cabin floor supports the seats above the lower fuselage.",mat:interior,layer:"interior")
        _=add("Cockpit instruments",SCNBox(width:0.36,height:0.16,length:0.08,chamferRadius:0.025),SCNVector3(0,0.04,-2.5),"The instrument panel gives pilots flight and engine information.",mat:dark,layer:"interior")
        let pilots=add("Pilot seats",SCNBox(width:0.15,height:0.22,length:0.22,chamferRadius:0.025),SCNVector3(-0.11,-0.02,-2.1),"Two pilot seats face the instrument panel.",mat:warm,layer:"interior")
        let second=SCNNode(geometry:pilots.geometry);second.position=SCNVector3(0.22,0,0);pilots.addChildNode(second)
        let seats=add("Passenger seats",SCNBox(width:0.14,height:0.22,length:0.19,chamferRadius:0.025),SCNVector3(-0.12,0,-1.45),"Passenger seats are arranged in rows on the cabin floor.",mat:warm,layer:"interior")
        for row in 0..<7{for side in 0..<2 where row != 0 || side != 0{let n=SCNNode(geometry:seats.geometry);n.position=SCNVector3(Double(side)*0.24,0,Double(row)*0.43);seats.addChildNode(n)}}
        let frames=add("Cabin frames",SCNTorus(ringRadius:0.31,pipeRadius:0.018),SCNVector3(0,0,-2.4),"Ring frames support the fuselage skin. This teaching cutaway simplifies the structure.",mat:interior,layer:"interior");frames.eulerAngles.x=CGFloat.pi/2
        for i in 1...11{let n=SCNNode(geometry:frames.geometry);n.position=SCNVector3(0,Float(i)*0.43,0);frames.addChildNode(n)}
        for sign in [CGFloat(-1),1]{
            let side=sign<0 ? "Left":"Right"
            let spar=add(side+" wing spar",SCNBox(width:3.4,height:0.08,length:0.1,chamferRadius:0.01),SCNVector3(sign*1.95,0.06,0.75),"The main wing spar carries bending loads from lift into the fuselage.",mat:interior,layer:"interior");spar.eulerAngles.y = sign>0 ? -0.28:0.28
            _=add(side+" fuel tank",SCNBox(width:1.4,height:0.12,length:0.4,chamferRadius:0.04),SCNVector3(sign*1.65,0.06,0.7),"Fuel is stored inside the wing near the main structural supports.",mat:warm,layer:"interior")
            for (name,z,radius,color,detail) in [("engine fan",-0.44,0.21,interior,"The fan accelerates air through and around the engine core."),("compressor",0.0,0.15,warm,"The compressor raises air pressure before combustion."),("turbine",0.8,0.16,interior,"The turbine extracts energy from hot gas to drive the compressor and fan.")]{
                let n=add(side+" "+name,SCNCylinder(radius:radius,height:0.13),SCNVector3(sign*1.2,-0.28,z),detail,mat:color,layer:"interior");n.eulerAngles.x=CGFloat.pi/2
                for blade in 0..<8{let b=SCNNode(geometry:SCNBox(width:0.025,height:0.015,length:radius*1.6,chamferRadius:0.005));b.geometry?.materials=[color];b.eulerAngles.y=CGFloat(blade)*CGFloat.pi/4;n.addChildNode(b)}
            }
        }
        let body=add("Fuselage",SCNCapsule(capRadius:0.36,height:7.1),SCNVector3(0,0,0),"The fuselage skin encloses the cabin and connects the major structures.",layer:"shell")
        body.eulerAngles.x=CGFloat.pi/2
        let nose=add("Nose",SCNCone(topRadius:0,bottomRadius:0.35,height:1.15),SCNVector3(0,0,-3.7),"The streamlined nose helps reduce drag.")
        nose.eulerAngles.x = -CGFloat.pi/2
        let cockpit=add("Cockpit",SCNSphere(radius:0.33),SCNVector3(0,0.27,-2.55),"The cockpit is where the pilot controls the aircraft.",mat:dark)
        cockpit.scale=SCNVector3(0.8,0.55,1.55)
        func wing(_ name:String,_ points:[CGPoint],_ detail:String) {
            let path=NSBezierPath();path.move(to:points[0]);for p in points.dropFirst(){path.line(to:p)};path.close()
            let shape=SCNShape(path:path,extrusionDepth:0.11);shape.chamferRadius=0.025
            let n=add(name,shape,SCNVector3(0,0.06,0),detail,layer:name.contains("wing") ? "shell":"structure");n.eulerAngles.x=CGFloat.pi/2
        }
        for sign in [CGFloat(-1),1] {
            wing(sign<0 ? "Left wing":"Right wing",[CGPoint(x:sign*0.27,y:-0.65),CGPoint(x:sign*4.45,y:1.4),CGPoint(x:sign*4.15,y:1.95),CGPoint(x:sign*0.28,y:0.95)],"The wing deflects air downward and creates a pressure distribution that produces lift.")
            wing(sign<0 ? "Left stabilizer":"Right stabilizer",[CGPoint(x:sign*0.2,y:2.15),CGPoint(x:sign*1.85,y:3.05),CGPoint(x:sign*1.7,y:3.45),CGPoint(x:sign*0.2,y:2.9)],"The horizontal stabilizer helps balance and control pitch.")
            let engine=add(sign<0 ? "Left engine":"Right engine",SCNCylinder(radius:0.26,height:1.65),SCNVector3(sign*1.2,-0.28,0.3),"The engine casing encloses the fan, compressor and turbine.",layer:"shell")
            engine.eulerAngles.x=CGFloat.pi/2
            let intake=add(sign<0 ? "Left engine intake":"Right engine intake",SCNCylinder(radius:0.21,height:0.05),SCNVector3(sign*1.2,-0.28,-0.54),"Air enters the engine here.",mat:dark,layer:"shell");intake.eulerAngles.x=CGFloat.pi/2
            let nozzle=add(sign<0 ? "Left engine nozzle":"Right engine nozzle",SCNTorus(ringRadius:0.22,pipeRadius:0.045),SCNVector3(sign*1.2,-0.28,1.13),"Exhaust leaves the nozzle at high speed.",mat:dark);nozzle.eulerAngles.x=CGFloat.pi/2
        }
        let finPath=NSBezierPath();finPath.move(to:CGPoint(x:-2.4,y:0.1));finPath.line(to:CGPoint(x:-3.15,y:1.6));finPath.line(to:CGPoint(x:-3.65,y:0.1));finPath.close()
        let fin=add("Vertical stabilizer",SCNShape(path:finPath,extrusionDepth:0.09),SCNVector3(-0.045,0,0),"The vertical stabilizer helps control yaw and keeps the aircraft directionally stable.")
        fin.eulerAngles.y=CGFloat.pi/2
        return root
    }
}

public enum SpatialExamples {
    public static var aircraft:SpatialScene {
        SpatialScene(title:"Why an airplane flies",summary:"Four forces act on an aircraft: lift, weight, thrust, and drag.",
            narration:"The wings generate lift upward, while gravity pulls the aircraft down. The engines produce thrust forward, and drag resists motion. In steady, level flight, these forces balance.",parts:[
                SpatialPart(name:"Aircraft",kind:"airplane",color:"white",detail:"Drag to view the aircraft from any angle. Click a wing, engine or stabilizer to inspect it."),
                SpatialPart(name:"Lift",kind:"arrow",position:Vector3(0,0.6,0),size:Vector3(0,2.7,0),color:"blue",detail:"Lift is the aerodynamic force perpendicular to the relative airflow."),
                SpatialPart(name:"Lift label",kind:"label",position:Vector3(0,3.8,0),size:Vector3(1.7,0.5,0.1),color:"blue",label:"Lift"),
                SpatialPart(name:"Weight",kind:"arrow",position:Vector3(0,-0.4,0),size:Vector3(0,-2.5,0),color:"yellow",detail:"Weight is the gravitational force on the aircraft."),
                SpatialPart(name:"Weight label",kind:"label",position:Vector3(0,-3.4,0),size:Vector3(1.9,0.5,0.1),color:"yellow",label:"Weight"),
                SpatialPart(name:"Thrust",kind:"arrow",position:Vector3(0,0,-3.9),size:Vector3(0,0,-2.1),color:"green",detail:"Thrust pushes the aircraft forward."),
                SpatialPart(name:"Thrust label",kind:"label",position:Vector3(0,0.6,-6.2),size:Vector3(1.7,0.5,0.1),color:"green",label:"Thrust"),
                SpatialPart(name:"Drag",kind:"arrow",position:Vector3(0,0,3.8),size:Vector3(0,0,2),color:"red",detail:"Drag is aerodynamic resistance opposite the motion through the air."),
                SpatialPart(name:"Drag label",kind:"label",position:Vector3(0,0.6,6.1),size:Vector3(1.7,0.5,0.1),color:"red",label:"Drag")
            ])
    }
}
