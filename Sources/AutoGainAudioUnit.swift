import AVFoundation
import AudioToolbox

private enum ParamAddress: AUParameterAddress {
    case target = 0
    case maxBoost = 1
    case maxCut = 2
    case fall = 3
    case clipRate = 4
    case release = 5
    case gate = 6
    case bypass = 7
    case rise = 8
    case ceiling = 9
    case limiterRelease = 10
    case limiter = 11
}

@objc(AutoGainAudioUnit)
public final class AutoGainAudioUnit: AUAudioUnit {

    // MARK: State

    private let state: UnsafeMutablePointer<AutoGainState>

    /// Pre-allocated channel pointer table. Gathering these into a Swift Array
    /// inside the render block would allocate; this is filled in place instead.
    private static let maxChannels = kMaxChannels
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputBusArrayStorage: AUAudioUnitBusArray!
    private var outputBusArrayStorage: AUAudioUnitBusArray!

    /// Scratch storage used when the host does not supply output buffer memory.
    private var scratch: AVAudioPCMBuffer?
    /// Stable cell holding the scratch buffer list pointer. The render block
    /// captures this cell, not the pointer itself, so it always sees the
    /// current allocation. Hosts are allowed to fetch the render block before
    /// allocateRenderResources, and a sample-rate change reallocates scratch;
    /// capturing the raw pointer would go stale in both cases.
    private let scratchCell: UnsafeMutablePointer<UnsafeMutablePointer<AudioBufferList>?>

    private var parameterTreeStorage: AUParameterTree!

    // MARK: Init

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {

        state = UnsafeMutablePointer<AutoGainState>.allocate(capacity: 1)
        state.initialize(to: AutoGainState())

        channelPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
            .allocate(capacity: AutoGainAudioUnit.maxChannels)
        channelPointers.initialize(repeating: nil,
                                   count: AutoGainAudioUnit.maxChannels)

        scratchCell = UnsafeMutablePointer<UnsafeMutablePointer<AudioBufferList>?>
            .allocate(capacity: 1)
        scratchCell.initialize(to: nil)

        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 8
        outputBus.maximumChannelCount = 8

        inputBusArrayStorage = AUAudioUnitBusArray(audioUnit: self,
                                                   busType: .input,
                                                   busses: [inputBus])
        outputBusArrayStorage = AUAudioUnitBusArray(audioUnit: self,
                                                    busType: .output,
                                                    busses: [outputBus])

        buildParameterTree()
        maximumFramesToRender = 4_096
    }

    deinit {
        // Order matters: the delay line is owned through the state struct, so
        // it must be released before the struct's memory goes away.
        autoGainFree(state)
        state.deinitialize(count: 1)
        state.deallocate()
        channelPointers.deinitialize(count: AutoGainAudioUnit.maxChannels)
        channelPointers.deallocate()
        scratchCell.deinitialize(count: 1)
        scratchCell.deallocate()
    }

    // MARK: Parameters

    private func buildParameterTree() {

        func param(_ address: ParamAddress,
                   _ identifier: String,
                   _ name: String,
                   _ unit: AudioUnitParameterUnit,
                   _ min: AUValue,
                   _ max: AUValue,
                   _ value: AUValue) -> AUParameter {
            let p = AUParameterTree.createParameter(
                withIdentifier: identifier,
                name: name,
                address: address.rawValue,
                min: min,
                max: max,
                unit: unit,
                unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
                valueStrings: nil,
                dependentParameters: nil)
            p.value = value
            return p
        }

        let params = [
            param(.target,   "target",   "Target",        .decibels, -24, 0,   -3),
            param(.maxBoost, "maxBoost", "Max Boost",     .decibels,   0, 24,   0),
            param(.maxCut,   "maxCut",   "Max Cut",       .decibels, -48, 0,  -24),
            param(.fall,     "rate",     "Fall Rate",     .rate,    0.02, 3,  0.2),
            param(.rise,     "rise",     "Rise Rate",     .rate,   0.002, 3, 0.02),
            param(.clipRate, "clipRate", "Clip Escape",   .ratio,      1, 10, 2.5),
            param(.release,  "release",  "Release",       .seconds, 0.25, 120,  3),
            param(.gate,     "gate",     "Gate",          .decibels, -90, -20, -56),
            param(.bypass,   "bypass",   "Bypass Gain",   .boolean,    0, 1,    0),
            param(.limiter,  "limiter",  "Limiter",       .boolean,    0, 1,    1),
            param(.ceiling,  "ceiling",  "Ceiling",       .decibels, -12, 0,   -1),
            param(.limiterRelease, "limiterRelease", "Lim Release",
                                                       .seconds, 0.005, 1, 0.08)
        ]

        let tree = AUParameterTree.createTree(withChildren: params)
        let s = state

        tree.implementorValueObserver = { parameter, value in
            switch ParamAddress(rawValue: parameter.address) {
            case .target:   s.pointee.targetDB = value
            case .maxBoost: s.pointee.maxBoostDB = value
            case .maxCut:   s.pointee.maxCutDB = value
            case .fall:     s.pointee.fallDBPerSec = value
            case .rise:     s.pointee.riseDBPerSec = value
            case .clipRate: s.pointee.clipRateMultiplier = value
            case .release:  s.pointee.releaseSeconds = value
            case .gate:     s.pointee.gateDB = value
            case .bypass:   s.pointee.bypassed = value
            case .limiter:  s.pointee.limiterEnabled = value
            case .ceiling:  s.pointee.ceilingDB = value
            case .limiterRelease: s.pointee.limiterReleaseSeconds = value
            case .none:     break
            }
        }

        tree.implementorValueProvider = { parameter in
            switch ParamAddress(rawValue: parameter.address) {
            case .target:   return s.pointee.targetDB
            case .maxBoost: return s.pointee.maxBoostDB
            case .maxCut:   return s.pointee.maxCutDB
            case .fall:     return s.pointee.fallDBPerSec
            case .rise:     return s.pointee.riseDBPerSec
            case .clipRate: return s.pointee.clipRateMultiplier
            case .release:  return s.pointee.releaseSeconds
            case .gate:     return s.pointee.gateDB
            case .bypass:   return s.pointee.bypassed
            case .limiter:  return s.pointee.limiterEnabled
            case .ceiling:  return s.pointee.ceilingDB
            case .limiterRelease: return s.pointee.limiterReleaseSeconds
            case .none:     return 0
            }
        }

        tree.implementorStringFromValueCallback = { parameter, valuePtr in
            let v = valuePtr?.pointee ?? parameter.value
            switch ParamAddress(rawValue: parameter.address) {
            case .fall, .rise: return String(format: "%.3f dB/s", v)
            case .clipRate: return String(format: "%.1f", v)
            case .release:  return String(format: "%.2f s", v)
            case .bypass, .limiter: return v > 0.5 ? "On" : "Off"
            case .limiterRelease: return String(format: "%.0f ms", v * 1000)
            default:        return String(format: "%.1f dB", v)
            }
        }

        parameterTreeStorage = tree
    }

    public override var parameterTree: AUParameterTree? {
        get { parameterTreeStorage }
        set { /* fixed tree */ }
    }

    /// Current leveller gain in dB, for the UI meter. Main thread only.
    @objc public var currentGainDB: Float { state.pointee.reportedGainDB }

    /// Deepest limiter reduction in the last buffer, dB. Main thread only.
    @objc public var currentLimitDB: Float { state.pointee.reportedLimitDB }

    /// Ask the control loop to snap gain to the current envelope on its next
    /// tick. A single Float store; safe from the main thread.
    @objc public func requestReseed() { state.pointee.reseedRequest = 1 }

    /// Sample rate the kernel is running at, for the UI's bin-to-frequency
    /// mapping. Main thread only.
    @objc public var currentSampleRate: Float { state.pointee.sampleRate }

    /// Enable or disable the spectrum tap. The UI turns it on only while the
    /// popover is visible so a hidden plugin does no per-sample tap work.
    @objc public func setSpectrumTap(_ on: Bool) {
        state.pointee.tapEnabled = on ? 1 : 0
    }

    /// Copy the most recent `count` tap samples, oldest first, into `buffer`.
    /// Returns false if the tap is not allocated or `count` exceeds capacity.
    /// A read racing the render thread tears a few samples at the seam; the
    /// display cannot show the difference.
    @objc public func copySpectrum(into buffer: UnsafeMutablePointer<Float>,
                                   count: Int) -> Bool {
        guard let tap = state.pointee.tap else { return false }
        let cap = Int(state.pointee.tapCapacity)
        guard count > 0, count <= cap else { return false }
        let w = Int(state.pointee.tapWrite)
        // Oldest of the window sits `count` behind the write cursor.
        var start = (w - count) % cap
        if start < 0 { start += cap }
        let firstRun = min(count, cap - start)
        buffer.update(from: tap + start, count: firstRun)
        if firstRun < count {
            (buffer + firstRun).update(from: tap, count: count - firstRun)
        }
        return true
    }

    // MARK: Presets

    private let factoryPresetDefs: [(name: String, values: [ParamAddress: AUValue])] = [
        ("Earshot Classic", [
            .target: -3, .maxBoost: 0, .maxCut: -24, .fall: 0.2, .rise: 0.2,
            .clipRate: 2.5, .release: 3, .gate: -56, .bypass: 0,
            .limiter: 1, .ceiling: -1, .limiterRelease: 0.08]),
        ("Volume Guard", [
            .target: -3, .maxBoost: 0, .maxCut: -24, .fall: 0.2, .rise: 0.02,
            .clipRate: 2.5, .release: 3, .gate: -56, .bypass: 0,
            .limiter: 1, .ceiling: -1, .limiterRelease: 0.08]),
        ("Source Leveller", [
            .target: -6, .maxBoost: 12, .maxCut: -24, .fall: 0.2, .rise: 0.05,
            .clipRate: 2.5, .release: 20, .gate: -50, .bypass: 0,
            .limiter: 1, .ceiling: -1, .limiterRelease: 0.08]),
    ]

    private lazy var factoryPresetObjects: [AUAudioUnitPreset] = {
        factoryPresetDefs.enumerated().map { index, def in
            let p = AUAudioUnitPreset()
            p.number = index
            p.name = def.name
            return p
        }
    }()

    public override var factoryPresets: [AUAudioUnitPreset]? { factoryPresetObjects }

    private var currentPresetStorage: AUAudioUnitPreset?
    public override var currentPreset: AUAudioUnitPreset? {
        get { currentPresetStorage }
        set {
            currentPresetStorage = newValue
            guard let preset = newValue, preset.number >= 0,
                  preset.number < factoryPresetDefs.count,
                  let tree = parameterTree else { return }
            for (address, value) in factoryPresetDefs[preset.number].values {
                tree.parameter(withAddress: address.rawValue)?.value = value
            }
        }
    }

    // MARK: Buses

    public override var inputBusses: AUAudioUnitBusArray { inputBusArrayStorage }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArrayStorage }
    public override var canProcessInPlace: Bool { true }

    // MARK: Lifecycle

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        guard outputBus.format.channelCount == inputBus.format.channelCount else {
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FailedInitialization))
        }

        scratch = AVAudioPCMBuffer(pcmFormat: inputBus.format,
                                   frameCapacity: maximumFramesToRender)
        scratchCell.pointee = scratch?.mutableAudioBufferList
        autoGainAllocate(state, sampleRate: outputBus.format.sampleRate)
    }

    public override func deallocateRenderResources() {
        scratchCell.pointee = nil
        scratch = nil
        autoGainFree(state)
        super.deallocateRenderResources()
    }

    /// The delay line runs whether or not the limiter is engaged, so the
    /// reported latency is constant and toggling the limiter never forces the
    /// host to renegotiate compensation.
    public override var latency: TimeInterval {
        Double(kLookaheadMilliseconds) / 1000.0
    }

    public override func reset() {
        autoGainReset(state)
    }

    // MARK: Render

    public override var internalRenderBlock: AUInternalRenderBlock {

        let s = state
        let pointers = channelPointers
        let maxChannels = AutoGainAudioUnit.maxChannels
        let scratchCell = self.scratchCell

        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in

            guard let pullInput = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }

            let outList = UnsafeMutableAudioBufferListPointer(outputData)

            // If the host handed us null buffer pointers it expects us to
            // supply storage. Point the output list at our scratch buffer
            // before pulling, so the pull lands somewhere valid.
            if outList.count > 0 && outList[0].mData == nil {
                guard let scratchList = scratchCell.pointee else {
                    return kAudioUnitErr_Uninitialized
                }
                let inList = UnsafeMutableAudioBufferListPointer(scratchList)
                let bytes = frameCount * UInt32(MemoryLayout<Float>.size)
                for i in 0..<min(outList.count, inList.count) {
                    outList[i].mNumberChannels = inList[i].mNumberChannels
                    outList[i].mDataByteSize = bytes
                    outList[i].mData = inList[i].mData
                }
            }

            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let err = pullInput(&pullFlags, timestamp, frameCount, 0, outputData)
            if err != noErr { return err }

            // Gather the channel pointers into the pre-allocated table.
            var channelCount = 0
            for i in 0..<min(outList.count, maxChannels) {
                guard let raw = outList[i].mData else { continue }
                pointers[channelCount] = raw.assumingMemoryBound(to: Float.self)
                channelCount += 1
            }
            guard channelCount > 0 else { return noErr }

            autoGainProcess(s,
                            channels: pointers,
                            channelCount: channelCount,
                            frameCount: Int(frameCount))

            return noErr
        }
    }
}
