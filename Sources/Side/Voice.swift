import AppKit
import AVFoundation
import SideCore

@MainActor final class VoiceRecorder:NSObject {
    private var engine:AVAudioEngine?
    private var recordingFile:AVAudioFile?
    private var activeID:UUID?
    private var meter:Timer?
    private var started=Date()
    private var lastSpeech=Date()
    private(set) var heardSpeech=false
    private var url:URL?
    private var noiseFloor:Float = -60
    private var lastPower:Float = -140
    private var receivedAudio=false
    private var speechEvidence=SpeechEvidence()
    private var samples=0
    private var diagnosticSecond = -1
    private(set) var voiceProcessingActive=false
    var onLevel:((Double)->Void)?
    var onAutoStop:(()->Void)?
    var onDiagnostics:(([String:Any])->Void)?
    var onError:((Error)->Void)?
    var isRecording:Bool {activeID != nil && engine?.isRunning == true}
    static var permitted:Bool {AVCaptureDevice.authorizationStatus(for:.audio) == .authorized}
    func start(voiceProcessing:Bool=true) async throws {
        let allowed=await AVCaptureDevice.requestAccess(for:.audio)
        try Task.checkCancellation()
        guard allowed else {throw SideAPIError("Enable Microphone for Side in System Settings to talk. You can also type a question.")}
        cancel()
        let audioEngine=AVAudioEngine()
        _=audioEngine.mainMixerNode
        let input=audioEngine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingAGCEnabled=true
                input.voiceProcessingOtherAudioDuckingConfiguration=AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking:true,duckingLevel:.mid)
            }catch{onDiagnostics?(["voiceProcessingFallback":error.localizedDescription])}
        }
        voiceProcessingActive=input.isVoiceProcessingEnabled
        let format=input.outputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0 else{throw SideAPIError("No microphone is connected. Choose an input device in Sound Settings.")}
        let target=FileManager.default.temporaryDirectory.appendingPathComponent("side-speech-\(UUID().uuidString).wav")
        let settings:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:format.sampleRate,
            AVNumberOfChannelsKey:format.channelCount,AVLinearPCMBitDepthKey:16,
            AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false]
        let file=try AVAudioFile(forWriting:target,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        let id=UUID()
        activeID=id;engine=audioEngine;recordingFile=file;url=target
        started=Date();lastSpeech=Date();heardSpeech=false;samples=0;diagnosticSecond = -1;lastPower = -140;receivedAudio=false;speechEvidence=SpeechEvidence()
        input.installTap(onBus:0,bufferSize:1024,format:format){[weak self] buffer,_ in
            do{try file.write(from:buffer)}catch{Task{@MainActor in if self?.activeID==id{self?.onError?(error)}}}
            guard let channel=buffer.floatChannelData?[0],buffer.frameLength>0 else{return}
            var energy:Float=0
            for i in 0..<Int(buffer.frameLength){energy+=channel[i]*channel[i]}
            let power=20*log10(max(0.0000001,sqrt(energy/Float(buffer.frameLength))))
            Task{@MainActor in if self?.activeID==id{self?.lastPower=power;self?.receivedAudio=true}}
        }
        do{audioEngine.prepare();try audioEngine.start()}catch{cancel();throw error}
        let timer=Timer(timeInterval:0.07,repeats:true){[weak self] _ in Task{@MainActor in self?.tick()}}
        meter=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func tick() {
        guard activeID != nil else{return}
        guard isRecording,receivedAudio else{
            if Date().timeIntervalSince(started)>4{onError?(SideAPIError("The microphone stopped delivering audio. Check the selected input device and try Talk again."))}
            return
        }
        let power=lastPower
        onLevel?(max(0,min(1,Double((power+55)/55))))
        let elapsed=Date().timeIntervalSince(started)
        if samples==0{noiseFloor=power}
        if elapsed<0.28{noiseFloor=(noiseFloor*Float(samples)+power)/Float(samples+1)}
        samples+=1
        let threshold=elapsed<0.28 ? Float(-24):min(-24,max(-48,noiseFloor+9))
        let sustained=speechEvidence.update(aboveThreshold:power>threshold,interval:0.07)
        if power>threshold,(heardSpeech || sustained){lastSpeech=Date();heardSpeech=true}
        if elapsed>=0.28,power<threshold{noiseFloor=noiseFloor*0.99+power*0.01}
        let second=Int(elapsed)
        if second != diagnosticSecond{
            diagnosticSecond=second
            onDiagnostics?(["elapsed":elapsed,"power":power,"threshold":threshold,"heardSpeech":heardSpeech,"recording":isRecording,"voiceProcessing":voiceProcessingActive])
        }
        if (heardSpeech && elapsed>1 && Date().timeIntervalSince(lastSpeech)>1.7) || elapsed>90{onAutoStop?()}
        if !heardSpeech && elapsed>12{onAutoStop?()}
    }
    func finish()->URL? {
        meter?.invalidate();meter=nil;activeID=nil
        engine?.stop();engine?.inputNode.removeTap(onBus:0);engine=nil;recordingFile=nil;onLevel?(0)
        defer{url=nil};return url
    }
    func cancel(){if let file=finish(){try? FileManager.default.removeItem(at:file)}}
}

@MainActor final class VoicePlayer:NSObject,AVAudioPlayerDelegate,AVSpeechSynthesizerDelegate {
    private var player:AVAudioPlayer?
    private let fallback=AVSpeechSynthesizer()
    var onFinished:(()->Void)?
    override init(){super.init();fallback.delegate=self}
    @discardableResult func play(_ data:Data) throws ->TimeInterval {
        stop();let p=try AVAudioPlayer(data:data);p.delegate=self;player=p
        guard p.play() else {throw SideAPIError("Audio playback could not start.")}
        return p.duration
    }
    func speakLocally(_ text:String) {stop();let utterance=AVSpeechUtterance(string:text);utterance.rate=0.49;fallback.speak(utterance)}
    func stop(){player?.stop();player=nil;fallback.stopSpeaking(at:.immediate)}
    nonisolated func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) {Task{@MainActor in self.onFinished?()}}
    nonisolated func speechSynthesizer(_ synthesizer:AVSpeechSynthesizer,didFinish utterance:AVSpeechUtterance) {Task{@MainActor in self.onFinished?()}}
}
