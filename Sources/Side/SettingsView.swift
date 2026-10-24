import SwiftUI
import AppKit
import SideCore

struct SettingsView:View {
    @ObservedObject var model:SideModel
    @State private var key=""
    @State private var message=""
    @State private var screenGranted=ScreenCapture.permitted
    @State private var micGranted=VoiceRecorder.permitted
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(spacing:12) {
                Image(systemName:"sparkle").font(.system(size:25)).foregroundStyle(Color(red:0.55,green:0.62,blue:0.39))
                VStack(alignment:.leading,spacing:3) {
                    Text("Side").font(.system(size:24,weight:.semibold,design:.rounded))
                    Text("Think out loud. Draw it together.").foregroundStyle(.secondary).font(.system(size:12))
                };Spacer()
            }
            VStack(alignment:.leading,spacing:10) {
                Label(model.keyReady ? "OpenAI key connected":"Connect OpenAI",systemImage:model.keyReady ? "checkmark.circle.fill":"key")
                    .font(.system(size:13,weight:.medium)).foregroundStyle(model.keyReady ? .green:.primary)
                HStack {
                    SecureField("OpenAI API key",text:$key).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        do {try KeyStore.save(key);key="";model.keyReady=true;message="Saved securely in your Mac Keychain."}
                        catch{message=error.localizedDescription}
                    }.disabled(key.isEmpty)
                }
                Text("The key stays in Keychain. Requests go directly to OpenAI.").font(.system(size:11)).foregroundStyle(.secondary)
                if !message.isEmpty{Text(message).font(.system(size:11)).foregroundStyle(.secondary)}
            }
            Divider()
            VStack(alignment:.leading,spacing:13) {
                Picker("Model",selection:$model.modelName) {
                    Text("GPT-6.1 Sol").tag("gpt-6.1-sol")
                    Text("GPT-6 Sol").tag("gpt-6-sol")
                    Text("GPT-5.6 Sol").tag("gpt-5.6-sol")
                }
                Toggle("Speak replies aloud",isOn:$model.voiceOutput)
                Toggle("Allow web research",isOn:$model.webEnabled)
                Toggle("Include a screenshot with my questions",isOn:$model.includeScreen)
                Text("Screen images are sent only when you ask a question or Sol requests a fresh look during that question. Nothing records in the background.")
                    .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.font(.system(size:12))
            Divider()
            VStack(alignment:.leading,spacing:12) {
                permissionRow("Screen Recording",subtitle:"See the app you're asking about.",granted:screenGranted) {
                    CGRequestScreenCaptureAccess()
                    if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {NSWorkspace.shared.open(url)}
                }
                permissionRow("Microphone",subtitle:"Ask questions with your voice.",granted:micGranted) {
                    Task {micGranted=await AVCaptureDevice.requestAccess(for:.audio)}
                }
            }
            HStack {
                Button("Drawing check"){model.drawingCheck()}
                Button("New conversation"){model.newConversation()}
                Spacer()
                Button("Quit Side"){NSApp.terminate(nil)}
            }.controlSize(.small)
            Text("⇧⌘Space  Talk / finish     ⇧⌘D  Open / close Side\nDrawings open as movable boards. Use Save SVG to export.")
                .font(.system(size:10.5)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(26).frame(width:470)
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in
            screenGranted=ScreenCapture.permitted;micGranted=VoiceRecorder.permitted
        }
    }
    func permissionRow(_ title:String,subtitle:String,granted:Bool,action:@escaping()->Void)->some View {
        HStack {
            VStack(alignment:.leading,spacing:3){Text(title).font(.system(size:12,weight:.medium));Text(subtitle).font(.system(size:11)).foregroundStyle(.secondary)}
            Spacer()
            if granted {Label("Allowed",systemImage:"checkmark.circle.fill").font(.system(size:11)).foregroundStyle(.green)}
            else {Button("Enable",action:action).controlSize(.small)}
        }
    }
}

import AVFoundation
