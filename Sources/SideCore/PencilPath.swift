import AppKit

/// Arc-length trimming keeps a moving pencil at a steady speed, even on unevenly sampled curves.
public enum PencilPath {
    public static func strokes(for e:DrawElement,in size:CGSize)->[[CGPoint]] {
        let r=DrawingRenderer.rect(e,in:size)
        switch e.kind {
        case "rect","highlight":
            let radius=min(9,r.height/6,r.width/6)
            var points:[CGPoint]=[]
            for (cx,cy,start) in [(r.maxX-radius,r.minY+radius,-Double.pi/2),
                                   (r.maxX-radius,r.maxY-radius,0.0),
                                   (r.minX+radius,r.maxY-radius,Double.pi/2),
                                   (r.minX+radius,r.minY+radius,Double.pi)] {
                for i in 0...8 {
                    let a=start+Double(i)/8*Double.pi/2
                    points.append(CGPoint(x:cx+cos(a)*radius,y:cy+sin(a)*radius))
                }
            }
            if let first=points.first{points.append(first)}
            return[points]
        case "ellipse":
            return[(0...120).map{i in
                let a=Double(i)/120*2*Double.pi-Double.pi/2
                return CGPoint(x:r.midX+cos(a)*r.width/2,y:r.midY+sin(a)*r.height/2)
            }]
        case "line","arrow":
            let a=DrawingRenderer.point(DrawPoint(e.x,e.y),in:size)
            let b=DrawingRenderer.point(DrawPoint(e.x+e.w,e.y+e.h),in:size)
            guard e.kind == "arrow" else{return[[a,b]]}
            let angle=atan2(b.y-a.y,b.x-a.x),length=max(11,e.strokeWidth*4)
            return[[a,b],[CGPoint(x:b.x-cos(angle-0.45)*length,y:b.y-sin(angle-0.45)*length),b,
                           CGPoint(x:b.x-cos(angle+0.45)*length,y:b.y-sin(angle+0.45)*length)]]
        case "path":return[e.points.map{DrawingRenderer.point($0,in:size)}]
        default:return[]
        }
    }
    public static func length(_ points:[CGPoint])->Double {
        zip(points,points.dropFirst()).reduce(0){$0+hypot($1.1.x-$1.0.x,$1.1.y-$1.0.y)}
    }
    public static func trimmed(_ strokes:[[CGPoint]],fraction:Double)->[[CGPoint]] {
        let f=min(1,max(0,fraction))
        if f>=1{return strokes};if f<=0{return[]}
        let total=strokes.reduce(0){$0+length($1)}
        var remaining=total*f,result:[[CGPoint]]=[]
        for points in strokes {
            guard let first=points.first else{continue}
            var partial=[first]
            for (a,b) in zip(points,points.dropFirst()) {
                let distance=hypot(b.x-a.x,b.y-a.y)
                if remaining>=distance {partial.append(b);remaining-=distance}
                else {
                    let t=distance>0 ? remaining/distance:0
                    partial.append(CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))
                    remaining=0;break
                }
            }
            result.append(partial)
            if remaining<=0{break}
        }
        return result
    }
    public static func draw(_ strokes:[[CGPoint]],fraction:Double,color:NSColor,width:Double) {
        let p=NSBezierPath();p.lineWidth=width;p.lineCapStyle = .round;p.lineJoinStyle = .round
        for points in trimmed(strokes,fraction:fraction) {
            guard let first=points.first else{continue};p.move(to:first)
            for point in points.dropFirst(){p.line(to:point)}
        }
        color.setStroke();p.stroke()
    }
    public static func tip(elements:[DrawElement],progress:Double,in size:CGSize)->CGPoint? {
        let position=Double(elements.count)*max(0,min(1,progress)),index=Int(position)
        guard index<elements.count else{return nil}
        let e=elements[index],fraction=position-Double(index)
        if e.kind == "text" {
            let r=DrawingRenderer.rect(e,in:size)
            return CGPoint(x:r.minX+r.width*fraction,y:r.minY+min(r.height,28))
        }
        return trimmed(strokes(for:e,in:size),fraction:fraction).last?.last
    }
}
