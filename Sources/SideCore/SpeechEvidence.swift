import Foundation

/// Require sustained voice energy so a click or a brief bump cannot submit a question.
public struct SpeechEvidence {
    private var duration:Double=0
    public init(){}
    public mutating func update(aboveThreshold:Bool,interval:Double)->Bool {
        duration=min(0.4,max(0,duration+(aboveThreshold ? interval : -interval*0.5)))
        return duration>=0.18
    }
}
