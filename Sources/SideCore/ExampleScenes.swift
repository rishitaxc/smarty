import Foundation

public enum ExampleScenes {
    /// A renderer fixture based on the tensor demonstration in the supplied references.
    /// Live requests always go to Sol; this scene is only used by the explicit drawing check.
    public static var tensor: DrawScene {
        var elements: [DrawElement] = [
            DrawElement("text", x:50,y:35,w:900,h:100,text:"2 rows × 4 columns",fontSize:34),
            DrawElement("text", x:50,y:150,w:900,h:80,text:"A tensor is a container for numbers.",fontSize:24)
        ]
        let values=[18,47,56,57,58,1,15,47]
        for col in 0..<4 { elements.append(DrawElement("text",x:Double(290+col*130),y:260,w:70,h:65,text:"\(col)",color:"gray",fontSize:22)) }
        for row in 0..<2 {
            elements.append(DrawElement("text",x:190,y:Double(355+row*155),w:60,h:70,text:"\(row)",color:"gray",fontSize:22))
            for col in 0..<4 {
                let selected = row == 1 && col == 2
                elements.append(DrawElement("rect",x:Double(260+col*130),y:Double(325+row*155),w:130,h:155,
                    text:"\(values[row*4+col])",color:selected ? "blue":"ink",fill:"blue",fontSize:28,strokeWidth:selected ? 3.5:1.4))
            }
        }
        elements += [
            DrawElement("text",x:65,y:700,w:410,h:85,text:"shape = (2, 4)",fontSize:28),
            DrawElement("text",x:510,y:700,w:430,h:85,text:"x[1, 2] = 15",color:"blue",fontSize:28),
            DrawElement("text",x:65,y:850,w:220,h:80,text:"x + 1",fontSize:28),
            DrawElement("arrow",x:290,y:880,w:120,h:0,color:"gray"),
            DrawElement("text",x:450,y:850,w:480,h:80,text:"19, 48, 57, 58…",color:"green",fontSize:26)
        ]
        return DrawScene(summary:"The drawing check shows a 2 × 4 tensor, row and column indices, and the selected value x[1, 2] = 15.",
            boards:[SketchBoard(id:"drawing-check",title:"Tensors, made visible",elements:elements)])
    }
}
