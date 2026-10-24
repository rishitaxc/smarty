import Foundation

public struct SpatialBuildStep:Codable,Equatable,Sendable {
    public var id:String
    public var title:String
    public var summary:String
    public var narration:String
    public var parts:[SpatialPart]
    public var reset:Bool
    public var complete:Bool
    public var interior:Bool
    public var showInterior:Bool
    public var boundsMin:Vector3
    public var boundsMax:Vector3
    public init(id:String,title:String,summary:String,narration:String,parts:[SpatialPart],reset:Bool,complete:Bool,interior:Bool,showInterior:Bool,boundsMin:Vector3,boundsMax:Vector3){
        self.id=id;self.title=title;self.summary=summary;self.narration=narration;self.parts=parts
        self.reset=reset;self.complete=complete;self.interior=interior;self.showInterior=showInterior;self.boundsMin=boundsMin;self.boundsMax=boundsMax
    }
    public func appending(to existing:SpatialScene?) throws ->SpatialScene{
        guard reset || existing?.id == id else{throw SideAPIError("Begin the live model with reset=true, then append using the same id.")}
        guard !parts.isEmpty,!narration.isEmpty,narration.count<=1800 else{throw SideAPIError("A live construction step needs new parts and a short spoken explanation.")}
        let values=[boundsMin.x,boundsMin.y,boundsMin.z,boundsMax.x,boundsMax.y,boundsMax.z]
        guard values.allSatisfy({$0.isFinite && abs($0)<=60}),boundsMax.x>boundsMin.x,boundsMax.y>boundsMin.y,boundsMax.z>boundsMin.z else{throw SideAPIError("Reserve finite bounds for the entire finished model.")}
        let previous=reset ? nil:existing
        let beats=(previous?.beats ?? [])+[SpatialBeat(narration:narration,parts:parts.map(\.name),interior:interior)]
        return try SpatialScene(id:id,title:title,summary:summary,narration:summary,parts:(previous?.parts ?? [])+parts,beats:beats,showInterior:showInterior).validated()
    }
}
