import Foundation

public enum SpatialSchema {
    static let vector=SceneSchema.object(["x":SceneSchema.number,"y":SceneSchema.number,"z":SceneSchema.number])
    public static let partSchema=SceneSchema.object([
        "name":SceneSchema.string,"kind":["type":"string","enum":["box","sphere","cylinder","cone","torus","arrow","label","mesh","airplane"]],
        "position":vector,"rotation":vector,"size":vector,"color":SceneSchema.string,"opacity":SceneSchema.number,"label":SceneSchema.string,"detail":SceneSchema.string,
        "layer":["type":"string","enum":["structure","shell","interior","annotation"]],
        "vertices":["type":"array","items":vector],"triangles":["type":"array","items":["type":"integer"]]
    ])
    public static let liveTool:[String:Any]=[
        "type":"function","name":"build_3d_step","strict":true,
        "description":"Construct real 3D LIVE in successive steps. Each call adds NEW named parts to the same visible model while narrating them. Use several calls, building the inside first, then the exterior. The user can inspect and orbit during construction. Do not repeat previous parts. Finish with complete=true only on the last construction step.",
        "parameters":SceneSchema.object([
            "id":SceneSchema.string,"title":SceneSchema.string,"summary":SceneSchema.string,"narration":SceneSchema.string,
            "parts":["type":"array","items":partSchema],"reset":["type":"boolean"],"complete":["type":"boolean"],"interior":["type":"boolean"],"showInterior":["type":"boolean"],"boundsMin":vector,"boundsMax":vector
        ])
    ]
    public static let schema=SceneSchema.object([
        "id":SceneSchema.string,"title":SceneSchema.string,"summary":SceneSchema.string,"narration":SceneSchema.string,"showInterior":["type":"boolean"],
        "beats":["type":"array","items":SceneSchema.object(["narration":SceneSchema.string,"parts":["type":"array","items":SceneSchema.string],"interior":["type":"boolean"]])],
        "parts":["type":"array","items":SceneSchema.object([
            "name":SceneSchema.string,"kind":["type":"string","enum":["box","sphere","cylinder","cone","torus","arrow","label","mesh","airplane"]],
            "position":vector,"rotation":vector,"size":vector,
            "color":SceneSchema.string,"opacity":SceneSchema.number,"label":SceneSchema.string,"detail":SceneSchema.string,
            "layer":["type":"string","enum":["structure","shell","interior","annotation"]],
            "vertices":["type":"array","items":vector],"triangles":["type":"array","items":["type":"integer"]]
        ])]
    ])
    public static let tool:[String:Any]=[
        "type":"function","name":"show_3d","strict":true,"parameters":schema,
        "description":"Build a real, interactive 3D scene floating above the desktop. The user can orbit, zoom, select named parts, hide labels, and ask follow-up questions. Use for explicit 3D requests. Supports arbitrary primitive assemblies and triangle meshes, plus a detailed procedural airplane. Positions are in world units, Y is up. Rotation is Euler degrees. See the instructions for size semantics. This is a scene graph, not executable code."
    ]
    public static let instructions="""
    LIVE 3D CONSTRUCTION: Prefer build_3d_step for every new 3D request, especially real-time construction, interiors and custom assemblies. Use 3 to 8 successive tool calls. The FIRST call has reset=true, complete=false and the first small group of actual parts. Subsequent calls have reset=false, the SAME id, and ONLY NEW parts. On the LAST construction call use complete=true, with the final actual parts or labels. Never stop before a complete=true construction call. Never repeat the completed model. Do not use show_3d to replay the same work.
    When asked to explain an existing model or selected part, answer with speech while leaving its geometry in place. Only build or change geometry when the user requests a new model or an actual modification. A follow-up explanation is not a request to reconstruct the model. Use smooth ellipsoids for organic torso forms, cylinders and spheres for limbs and joints; reserve boxes for actual rigid hardware.
    Reserve boundsMin/boundsMax for the FINISHED model in the first call, including labels, and keep these stable across calls. The workspace uses these bounds to keep the model centered. Add a few logical components per call, with a concise narration explaining precisely those parts. Build internal geometry before the shell. Every call appears immediately on the user's desktop and speaks its narration while assembling those parts. You may plan the next step while the current one is being narrated. summary can be updated as you build. showInterior controls whether the final shell is translucent; interior controls the current step's cutaway. The geometries and dimensions below apply to both 3D tools.
    Use the 3D tools when the user explicitly asks for a 3D model or for spatial/physical visualization. Keep ordinary diagrams, math, and tensors in 2D sketch boards by default. 3D scenes are real native geometry with camera orbit, zoom, part selection, reset, and rotation controls. Never substitute a flat picture for requested 3D.
    Use a persistent id such as aircraft, motor or molecule. Update the full scene for that id when following up. The workspace opens on the left and BUILDS LIVE, part by part, synchronized to your spoken construction beats. Never dump the finished model all at once. summary explains the result and contains source links if researched. narration is an overall description, but is not repeated after the beats.
    For show_3d only, provide 3 to 10 beats (up to 16 for a complex model). Each beat contains a short spoken narration, parts with exact part names to add in that step, and interior=true to reveal internal structures by fading shell parts. Every part including labels must appear in at least one beat. The renderer animates each part individually within the spoken step. For either tool, build the internal structure first, then the outer shell, then explanatory arrows. Use showInterior=true when the user asks to see the inside, so the finished shell remains translucent. Otherwise false. Keep the explanation specific to the new parts.
    Every part has a layer: interior for actual internal geometry, shell for housing/skin that Inside mode fades, structure for exposed components, annotation for arrows and labels. Model meaningful internal components when asked to show the inside. A solid outside with a low opacity is not an interior. For example, an electric motor needs an actual shaft, rotor, stator, coils, bearings and outer housing. These are simplified educational models, not fabrication-ready CAD. Never invent precise mechanical specifications.
    Each part needs a unique, meaningful name and a short detail explaining what that part does. The user can click geometry and ask about it. All fields are required. Use label="" except for label geometry. vertices=[] and triangles=[] unless kind is mesh. opacity usually 1. color uses names or #RRGGBB.
    World units: Y is up, X is right, Z is depth. Most objects should fit inside roughly +/-5 units. size for box is width/height/depth, for sphere is three diameters, for cylinder/cone is diameter/height/diameter, for torus scales its unit ring. Primitives point along local +Y before rotation. rotation is XYZ degrees. Use separate named parts for meaningful structures.
    An arrow starts at position and size is its DIRECTION VECTOR to the tip, including negative components, NOT its scale. For example, upward lift is size {x:0,y:3,z:0}. A label is a camera-facing text card; size.x is its world width, size.y is height, and size.z should be 0.1. Put labels beyond arrow tips or beside the relevant parts with enough space.
    For a teaching aircraft use one airplane part with size {x:1,y:1,z:1}, rotation 0, and position 0. It includes the cabin, seats, instruments, wing spars, fuel tanks, engine fans, compressors, turbines and outer airframe. The 7.5-unit fuselage runs along Z, nose toward -Z; wings span about +/-4.5 X. Each component is individually selectable. With an airplane part named Aircraft, use names such as Aircraft/Cabin floor in beats to construct subparts separately. Available subparts, in sensible build order: \(SpatialBuilder.aircraftComponents.joined(separator:", ")). Include every one, or use the parent name Aircraft to build any remaining components sequentially. Prefer several small groups rather than one whole-airplane beat. To show forces, add arrows/labels outside the body: lift +Y, weight -Y, thrust -Z, drag +Z. Keep annotations sparse and readable.
    Arbitrary meshes use local vertices and a flat zero-based triangle-index array. Indices must be valid and grouped in threes. The renderer computes normals. The mesh is placed at position, with rotation, and vertices are already in world-sized local units; size is ignored for mesh. For molecule bonds you may use cylinders oriented between atoms or arrows if direction matters. Build the requested subject, not a canned aircraft for unrelated questions.
    """
}
