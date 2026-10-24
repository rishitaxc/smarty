import Foundation

public struct SpatialOrbit:Equatable,Sendable {
    public let target:Vector3
    public let homeDistance:Double
    public private(set) var distance:Double
    public private(set) var yaw:Double=0.6337
    public private(set) var pitch:Double=0.3906
    public init(min:Vector3,max:Vector3,aspect:Double){
        target=Vector3((min.x+max.x)/2,(min.y+max.y)/2,(min.z+max.z)/2)
        let dx=max.x-min.x,dy=max.y-min.y,dz=max.z-min.z
        let radius=Swift.max(0.65,sqrt(dx*dx+dy*dy+dz*dz)/2)
        let vertical=46*Double.pi/180
        let horizontal=2*atan(tan(vertical/2)*Swift.max(0.45,aspect))
        homeDistance=radius/sin(Swift.min(vertical,horizontal)/2)*1.08
        distance=homeDistance
    }
    public var position:Vector3{Vector3(target.x+sin(yaw)*cos(pitch)*distance,target.y+sin(pitch)*distance,target.z+cos(yaw)*cos(pitch)*distance)}
    public mutating func rotate(dx:Double,dy:Double){yaw-=dx*0.009;pitch=Swift.max(-1.25,Swift.min(1.25,pitch+dy*0.009))}
    public mutating func zoom(delta:Double){distance=Swift.max(homeDistance*0.38,Swift.min(homeDistance*2.8,distance*exp(Swift.max(-1,Swift.min(1,delta)))))}
    public mutating func reset(){distance=homeDistance;yaw=0.6337;pitch=0.3906}
}
