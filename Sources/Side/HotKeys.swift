import Foundation
import Carbon

final class HotKeys {
    private var refs:[EventHotKeyRef?]=[]
    private var handler:EventHandlerRef?
    private var escape:EventHotKeyRef?
    var onPress:((UInt32)->Void)?
    init() {
        var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{_,event,context in
            guard let event,let context else{return noErr}
            var id=EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,
                              MemoryLayout<EventHotKeyID>.size,nil,&id)
            let owner=Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {owner.onPress?(id.id)}
            return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&handler)
        for (id,key) in [(UInt32(1),UInt32(kVK_Space)),(UInt32(2),UInt32(kVK_ANSI_D))] {
            var ref:EventHotKeyRef?
            RegisterEventHotKey(key,UInt32(cmdKey|shiftKey),EventHotKeyID(signature:0x53494445,id:id),GetApplicationEventTarget(),0,&ref)
            refs.append(ref)
        }
    }
    func setEscapeEnabled(_ enabled:Bool) {
        if enabled,escape == nil {RegisterEventHotKey(UInt32(kVK_Escape),0,EventHotKeyID(signature:0x53494445,id:3),GetApplicationEventTarget(),0,&escape)}
        else if !enabled,let escape{UnregisterEventHotKey(escape);self.escape=nil}
    }
    deinit{for ref in refs {if let ref{UnregisterEventHotKey(ref)}};if let escape{UnregisterEventHotKey(escape)};if let handler {RemoveEventHandler(handler)}}
}
