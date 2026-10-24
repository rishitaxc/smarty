import SwiftUI
import AppKit


struct SideButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label.opacity(configuration.isPressed ? 0.7:1)
            .scaleEffect(configuration.isPressed ? 0.97:1)
    }
}

struct VoiceBars:View {
    let level:Double
    let active:Bool
    let color:Color
    var body:some View {
        TimelineView(.animation(minimumInterval:0.12,paused:!active)) { timeline in
            let t=timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing:3) {
                ForEach(0..<5) {i in
                    let height=active ? 5+abs(sin(t*4+Double(i)*1.2))*(8+level*13):Double([6,11,16,10,5][i])
                    Capsule().fill(color).frame(width:3,height:height)
                }
            }.frame(width:29,height:26)
        }.accessibilityHidden(true)
    }
}

struct NotchView:View {
    @ObservedObject var model:SideModel
    let topInset:CGFloat
    let cameraWidth:CGFloat
    @FocusState private var inputFocused:Bool
    var showStop:Bool {model.busy || (model.activity == .speaking && model.draft.isEmpty)}
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Button {model.expanded.toggle()} label:{
                    Image(systemName:"sparkle").font(.system(size:17,weight:.medium)).foregroundStyle(model.accent)
                        .frame(width:36,height:30).contentShape(Rectangle())
                }.accessibilityLabel("Open Side")
                Spacer(minLength:cameraWidth)
                Button {model.toggleVoice()} label:{VoiceBars(level:model.level,active:[.listening,.thinking,.speaking].contains(model.activity),color:model.accent).frame(width:36,height:30)}
                    .accessibilityLabel(model.activity == .listening ? "Finish recording":"Talk to Side")
            }.padding(.horizontal,14).frame(height:max(34,topInset))
            if model.expanded {
                expandedContent.padding(.horizontal,23).padding(.top,13).padding(.bottom,19)
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        .foregroundStyle(.white)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius:model.expanded ? 25:15,bottomTrailingRadius:model.expanded ? 25:15))
        .overlay(alignment:.bottom){
            if model.expanded {RoundedRectangle(cornerRadius:2).fill(.white.opacity(0.18)).frame(width:32,height:3).padding(.bottom,6)}
        }
        .buttonStyle(SideButtonStyle())
        .preferredColorScheme(.dark)
        .onExitCommand{if model.busy || model.activity == .speaking{model.stop()}else{model.expanded=false}}
    }
    var expandedContent:some View {
        VStack(alignment:.leading,spacing:15) {
            HStack {
                HStack(spacing:7) {
                    Circle().fill(model.accent).frame(width:5,height:5)
                    Text("SIDE").font(.system(size:10,weight:.semibold)).tracking(2.4)
                }.foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text(model.activity == .idle ? "GPT SOL":model.activity.rawValue.uppercased())
                    .font(.system(size:9,weight:.medium)).tracking(1.3).foregroundStyle(model.accent)
                Button {model.onSettings?()} label:{Image(systemName:"slider.horizontal.3").font(.system(size:12))}
                    .foregroundStyle(.white.opacity(0.5)).help("Settings").accessibilityLabel("Side Settings")
            }
            if !model.error.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    Text(model.error).font(.system(size:12)).foregroundStyle(Color(red:1,green:0.65,blue:0.6)).fixedSize(horizontal:false,vertical:true)
                    HStack {
                        Button("Open Settings"){model.onSettings?()}
                        Spacer()
                        if !model.lastQuestion.isEmpty {Button("Try again"){model.submit(model.lastQuestion)}}
                    }.font(.system(size:11,weight:.medium)).foregroundStyle(.white.opacity(0.75))
                }.frame(maxHeight:110)
            } else if model.response.isEmpty && !model.busy {
                VStack(alignment:.leading,spacing:6) {
                    Text("Talk it through.\nSee it take shape.").font(.system(size:25,weight:.medium,design:.rounded)).tracking(-0.6)
                    Text(model.includeScreen ? "Ask about anything on your screen.":"Your voice, a blank page, any idea.").font(.system(size:12)).foregroundStyle(.white.opacity(0.45))
                }.padding(.vertical,3)
            } else {
                if !model.lastQuestion.isEmpty {
                    Text(model.lastQuestion).font(.system(size:11)).foregroundStyle(.white.opacity(0.42)).lineLimit(2)
                }
                if model.activity == .listening {
                    HStack(spacing:12){VoiceBars(level:model.level,active:true,color:model.accent);Text("I'm listening…").font(.system(size:20,weight:.medium,design:.rounded))}
                        .frame(maxWidth:.infinity,minHeight:55,alignment:.leading)
                } else if model.response.isEmpty {
                    HStack(spacing:10){ProgressView().controlSize(.small);Text(model.activity == .transcribing ? "Turning your words into a question…":"Thinking with Sol…").font(.system(size:13)).foregroundStyle(.white.opacity(0.7))}
                        .frame(minHeight:45)
                } else {
                    ScrollView {
                        Text(.init(model.response)).font(.system(size:12.5)).lineSpacing(4)
                            .foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:116)
                    if !model.sources.isEmpty {
                        ScrollView(.horizontal,showsIndicators:false) {
                            HStack {ForEach(Array(model.sources.prefix(4).enumerated()),id:\.offset) {_,source in
                                if let url=URL(string:source.url) {Link(source.title,destination:url).font(.system(size:10)).lineLimit(1).frame(maxWidth:170)}
                            }}
                        }.frame(height:17)
                    }
                }
            }
            if !model.note.isEmpty {Text(model.note).font(.system(size:10)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)}
            HStack(spacing:13) {
                Button {model.toggleVoice()} label:{
                    HStack(spacing:12) {
                        ZStack {
                            Circle().fill(model.accent.opacity(model.activity == .listening ? 0.22:1)).frame(width:43,height:43)
                            if model.activity == .listening {
                                VoiceBars(level:model.level,active:true,color:model.accent)
                            }else{Image(systemName:"mic.fill").font(.system(size:17,weight:.medium)).foregroundStyle(.black)}
                        }
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.activity == .listening ? "Listening…":model.busy || model.activity == .speaking ? "Talk to interrupt":"Talk to Side")
                                .font(.system(size:14,weight:.medium))
                            Text(model.activity == .listening ? "Pause, or tap to send.":model.conversationMode ? "Conversation is on":"Start a voice conversation")
                                .font(.system(size:10.5)).foregroundStyle(.white.opacity(0.4))
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.accessibilityLabel(model.activity == .listening ? "Finish recording":"Start voice conversation")
                if model.conversationMode {
                    Button {model.stop()} label:{Image(systemName:"phone.down.fill").font(.system(size:12)).foregroundStyle(.white.opacity(0.6)).frame(width:27,height:35)}
                        .help("End voice conversation").accessibilityLabel("End voice conversation")
                }
                Button {model.typing.toggle();inputFocused=model.typing} label:{
                    Image(systemName:"keyboard").font(.system(size:15)).foregroundStyle(.white.opacity(model.typing ? 0.9:0.4)).frame(width:27,height:35)
                }.help("Type a question").accessibilityLabel("Type a question")
            }.padding(12).background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:15))
            if model.typing || !model.draft.isEmpty {
            VStack(spacing:0) {
                HStack(alignment:.center,spacing:10) {
                    TextField("Ask anything. I'll draw it.",text:$model.draft,axis:.vertical)
                        .textFieldStyle(.plain).font(.system(size:13)).lineLimit(1...3)
                        .focused($inputFocused).onSubmit{model.submit()}
                        .accessibilityLabel("Ask Side")
                    Button {showStop ? model.stop():model.submit()} label:{
                        Image(systemName:showStop ? "stop.fill":"arrow.up").font(.system(size:12,weight:.semibold))
                            .foregroundStyle(.black).frame(width:28,height:28).background(model.accent,in:Circle())
                    }.disabled(!showStop && model.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .opacity(!showStop && model.draft.isEmpty ? 0.35:1)
                        .accessibilityLabel(showStop ? "Stop Side":"Send question")
                }.padding(12)
            }.background(.white.opacity(0.075),in:RoundedRectangle(cornerRadius:13))
            }
            HStack(spacing:12) {
                Text("⇧ ⌘ SPACE").font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(.white.opacity(0.25))
                Spacer()
                if model.hasSpatialModel{
                    Button{model.showSpatial()}label:{Image(systemName:"cube.transparent").foregroundStyle(.white.opacity(0.5))}.help("Show the current 3D model").accessibilityLabel("Show 3D model")
                }
                if !model.response.isEmpty && !model.busy && model.latestSpatial == nil {
                    Button {model.replay()} label:{Image(systemName:"play.circle").foregroundStyle(.white.opacity(0.5))}.help("Replay explanation and drawing").accessibilityLabel("Replay drawing explanation")
                }
                Button {model.includeScreen.toggle()} label:{
                    HStack(spacing:5){Image(systemName:model.includeScreen ? "rectangle.inset.filled.badge.record":"rectangle.slash");Text(model.includeScreen ? "Screen on":"Screen off").font(.system(size:10))}
                        .foregroundStyle(model.includeScreen ? model.accent:.white.opacity(0.35))
                }
                    .help(model.includeScreen ? "Screen included with your next question":"Screen is off. Click to include it.").accessibilityLabel(model.includeScreen ? "Turn screen sharing off":"Turn screen sharing on")
                Button {model.voiceOutput.toggle()} label:{Image(systemName:model.voiceOutput ? "speaker.wave.2":"speaker.slash").foregroundStyle(.white.opacity(0.5))}
                    .help("Toggle spoken replies").accessibilityLabel(model.voiceOutput ? "Mute spoken replies":"Enable spoken replies")
                if model.boardCount>0 {
                    Button {model.clearDrawings()} label:{Image(systemName:"eraser").foregroundStyle(.white.opacity(0.5))}
                        .help("Clear drawings").accessibilityLabel("Clear all drawings")
                }
            }.font(.system(size:12))
        }
    }
}
