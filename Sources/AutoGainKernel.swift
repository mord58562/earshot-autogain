import Foundation

/// Look-ahead window for the output limiter, in milliseconds.
///
/// Fixed rather than exposed as a parameter. Changing it would alter the unit's
/// reported latency and require reallocating the delay line mid-stream, and
/// 5 ms is comfortably enough to catch anything the gain stage lets through.
let kLookaheadMilliseconds: Float = 5.0

/// Largest channel count the delay line is sized for.
let kMaxChannels: Int = 8

/// Length of the spectrum tap ring, and therefore the FFT size the UI runs.
/// 4096 samples is about 93 ms at 44.1 kHz: roughly 11 Hz resolution, which
/// resolves the bass end of an EQ curve without smearing time badly.
let kSpectrumTapSamples: Int32 = 4096

/// Plain-old-data render state.
///
/// This is deliberately a `struct` held behind an `UnsafeMutablePointer` so the
/// render block touches no Swift objects, takes no retain/release traffic, and
/// allocates nothing. It mirrors the discipline in Earshot's own audio thread,
/// where the source node render block is a `memcpy` plus an atomic add.
struct AutoGainState {

    // MARK: Leveller tunables
    //
    // Written from the parameter tree on the main thread, read on the render
    // thread. Float stores are atomic on arm64 and a torn read is impossible,
    // so the worst case is that a parameter change lands one tick late.

    /// The level the envelope is steered toward, in dBFS. Earshot aims at -3.
    var targetDB: Float = -3.0
    /// Ceiling on gain. Earshot hard-caps at 0 dB so Auto only ever attenuates.
    /// Raise this above zero to convert the algorithm into an upward leveller.
    var maxBoostDB: Float = 0.0
    /// Floor on gain. Earshot clamps at -24 dB.
    var maxCutDB: Float = -24.0
    /// Downward movement rate in dB per second: how fast the algorithm pulls
    /// gain back when the programme gets louder. Earshot uses 0.2, chosen to
    /// sit below the roughly 0.4 dB/sec perceptibility threshold for slow gain
    /// changes during programme material.
    var fallDBPerSec: Float = 0.2
    /// Upward movement rate in dB per second: how fast gain is recovered when
    /// the programme gets quieter.
    ///
    /// Earshot used one rate in both directions, which is defensible when gain
    /// is hard-capped at unity and the algorithm is only ever undoing its own
    /// attenuation on speech-like material. On music it is not: a quiet passage
    /// lasting a minute recovers a full 12 dB at 0.2 dB/sec, and although no
    /// individual moment is perceptible, the arrival very much is. Recovery
    /// therefore defaults an order of magnitude slower than protection, so gain
    /// only climbs if the source is sustainably quiet rather than momentarily
    /// so.
    var riseDBPerSec: Float = 0.02
    /// Multiplier applied to the downward rate while the input is clipping.
    var clipRateMultiplier: Float = 2.5
    /// Peak-follower release time constant in seconds. Earshot's 0.987 per
    /// 40 ms tick works out at very close to 3 s.
    var releaseSeconds: Float = 3.0
    /// Freeze threshold in dBFS. Below this the algorithm parks, so a paused
    /// source cannot convince it to recover gain and then slam it back down.
    var gateDB: Float = -56.0
    /// Non-zero bypasses the gain stage but keeps the envelope running, so
    /// un-bypassing does not start from a cold envelope.
    var bypassed: Float = 0
    /// One-shot request from the UI thread. When non-zero, the next control
    /// tick snaps gain directly to what the current envelope calls for,
    /// bypassing the rate limits for that single step. This exists because the
    /// deliberately slow rise rate, correct for quiet passages inside a track,
    /// makes an intentional switch to a quieter source take minutes to settle;
    /// the listener knows the difference even though the algorithm cannot.
    var reseedRequest: Float = 0

    // MARK: Limiter tunables

    /// Non-zero engages gain reduction. The delay line runs either way, so
    /// toggling this never changes the unit's latency and never clicks.
    var limiterEnabled: Float = 1
    /// Brickwall ceiling in dBFS.
    var ceilingDB: Float = -1.0
    /// Limiter release time constant in seconds.
    var limiterReleaseSeconds: Float = 0.08

    // MARK: Derived at prepare time

    var sampleRate: Float = 48_000
    /// Frames in one 40 ms control tick.
    var framesPerTick: Int32 = 1_920
    /// Delay line length per channel, equal to the look-ahead window.
    var lookaheadSamples: Int32 = 240
    /// Channels the delay line was allocated for.
    var delayChannels: Int32 = 0
    /// Interleaved-by-channel delay storage, `delayChannels * lookaheadSamples`
    /// floats. Owned by the audio unit, allocated outside the render thread.
    var delay: UnsafeMutablePointer<Float>? = nil

    // MARK: Spectrum tap

    /// Non-zero while the plugin UI is on screen. The tap costs one add and
    /// one store per sample when enabled and a single flag test when not, so
    /// a closed popover costs effectively nothing, matching Earshot's habit
    /// of gating pure-UI work behind visibility.
    var tapEnabled: Float = 0
    /// Mono ring buffer of post-limiter output for the spectrum display.
    /// Single writer (render thread), single reader (main thread). A read
    /// racing a write tears a handful of samples at the seam, which is
    /// harmless for a display and not worth a lock on the audio thread.
    var tap: UnsafeMutablePointer<Float>? = nil
    var tapCapacity: Int32 = 0
    var tapWrite: Int32 = 0

    // MARK: Leveller running state

    /// Peak-follower output, linear.
    var envelope: Float = 0
    /// Frames accumulated since the last control tick.
    var tickFrames: Int32 = 0
    /// Peak observed since the last control tick, linear, post-gain.
    var tickPeak: Float = 0
    /// Gain the algorithm wants, in dB.
    var gainDB: Float = 0
    /// Gain actually applied at the end of the previous buffer, in dB. The
    /// buffer ramps from here to `gainDB` so no step lands on a sample edge.
    var appliedGainDB: Float = 0
    /// Published to the UI. Never read on the render thread.
    var reportedGainDB: Float = 0

    // MARK: Limiter running state

    /// Write cursor into the delay line.
    var delayWrite: Int32 = 0
    /// Linked peak detector, reading the signal before it enters the delay.
    var peakEnv: Float = 0
    /// Samples remaining before `peakEnv` may begin releasing. Set to the
    /// look-ahead length whenever a new peak is captured, so the envelope
    /// cannot decay before the peak that set it has cleared the delay line.
    /// Without this, a short transient overshoots the ceiling: the detector
    /// relaxes while the spike is still in flight, and the gain has drifted
    /// back up by the time it emerges. Verified numerically, ~0.06 dB over.
    var peakHold: Int32 = 0
    /// Current limiter gain, linear, always <= 1.
    var limGain: Float = 1
    /// Deepest reduction in the last buffer, dB. Published to the UI only.
    var reportedLimitDB: Float = 0
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Resets the running state without disturbing the tunables. Called on
/// allocate and on reset, matching `setAutoPreampEnabled`'s behaviour of
/// zeroing the envelope whenever the feature is re-engaged.
@inline(__always)
func autoGainReset(_ s: UnsafeMutablePointer<AutoGainState>) {
    s.pointee.envelope = 0
    s.pointee.tickFrames = 0
    s.pointee.tickPeak = 0
    s.pointee.gainDB = min(0, s.pointee.maxBoostDB)
    s.pointee.appliedGainDB = s.pointee.gainDB
    s.pointee.reportedGainDB = s.pointee.gainDB
    s.pointee.reseedRequest = 0

    s.pointee.delayWrite = 0
    s.pointee.peakEnv = 0
    s.pointee.peakHold = 0
    s.pointee.limGain = 1
    s.pointee.reportedLimitDB = 0
    s.pointee.tapWrite = 0
    if let t = s.pointee.tap {
        let n = Int(s.pointee.tapCapacity)
        if n > 0 { t.update(repeating: 0, count: n) }
    }

    // Silence the delay line so a restart cannot flush stale audio.
    if let d = s.pointee.delay {
        let count = Int(s.pointee.delayChannels) * Int(s.pointee.lookaheadSamples)
        if count > 0 { d.update(repeating: 0, count: count) }
    }
}

/// Allocates the look-ahead delay line and recomputes sample-rate-dependent
/// constants. Must be called off the render thread, from
/// `allocateRenderResources`.
func autoGainAllocate(_ s: UnsafeMutablePointer<AutoGainState>,
                      sampleRate: Double) {
    autoGainFree(s)

    let sr = Float(sampleRate)
    s.pointee.sampleRate = sr
    s.pointee.framesPerTick = max(1, Int32(sr * 0.04))
    s.pointee.lookaheadSamples = max(1, Int32(sr * kLookaheadMilliseconds / 1000))
    s.pointee.delayChannels = Int32(kMaxChannels)

    let count = kMaxChannels * Int(s.pointee.lookaheadSamples)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
    buffer.initialize(repeating: 0, count: count)
    s.pointee.delay = buffer

    let tapCount = Int(kSpectrumTapSamples)
    let tap = UnsafeMutablePointer<Float>.allocate(capacity: tapCount)
    tap.initialize(repeating: 0, count: tapCount)
    s.pointee.tap = tap
    s.pointee.tapCapacity = kSpectrumTapSamples

    autoGainReset(s)
}

/// Releases the delay line. Safe to call twice.
func autoGainFree(_ s: UnsafeMutablePointer<AutoGainState>) {
    if let d = s.pointee.delay {
        let count = Int(s.pointee.delayChannels) * Int(s.pointee.lookaheadSamples)
        d.deinitialize(count: max(0, count))
        d.deallocate()
    }
    s.pointee.delay = nil
    s.pointee.delayChannels = 0

    if let t = s.pointee.tap {
        t.deinitialize(count: max(0, Int(s.pointee.tapCapacity)))
        t.deallocate()
    }
    s.pointee.tap = nil
    s.pointee.tapCapacity = 0
}

// ---------------------------------------------------------------------------
// Leveller
// ---------------------------------------------------------------------------

/// The control-rate update. One call per 40 ms of audio.
///
/// This is the port of `AppState.autoAdjustPreamp`. The only structural change
/// is that step sizes are derived from the elapsed time rather than hard-coded
/// as 0.008 dB, so the movement rate stays exact whatever buffer size the host
/// hands us. Earshot could assume 40 ms ticks because it owned its own tap; an
/// Audio Unit cannot.
@inline(__always)
private func autoGainTick(_ s: UnsafeMutablePointer<AutoGainState>,
                          peak linearPeak: Float,
                          dt: Float) {

    // Peak follower: instant attack, exponential release. The slow release is
    // what gives the system its anticipation. Once a peak has set the envelope
    // high it stays high for several seconds even if the programme briefly
    // quietens, so gain is not recovered straight into the next transient.
    if linearPeak > s.pointee.envelope {
        s.pointee.envelope = linearPeak
    } else {
        let tau = max(0.05, s.pointee.releaseSeconds)
        s.pointee.envelope *= expf(-dt / tau)
    }

    // Noise gate. Freeze during true silence.
    let floorLinear = powf(10, s.pointee.gateDB / 20)
    if s.pointee.envelope <= floorLinear {
        s.pointee.reseedRequest = 0
        return
    }

    let envelopeDB = 20 * log10f(max(s.pointee.envelope, 1e-5))
    let delta = s.pointee.targetDB - envelopeDB

    // One-shot reseed: jump straight to the required gain, clamped to the
    // usual bounds, then resume normal rate-limited operation.
    if s.pointee.reseedRequest != 0 {
        s.pointee.reseedRequest = 0
        let lo = min(s.pointee.maxCutDB, s.pointee.maxBoostDB)
        let hi = max(s.pointee.maxCutDB, s.pointee.maxBoostDB)
        s.pointee.gainDB = max(lo, min(hi, s.pointee.gainDB + delta))
        s.pointee.reportedGainDB = s.pointee.gainDB
        return
    }

    // Movement caps, asymmetric. Protection moves at the fall rate; recovery
    // at the rise rate, which is normally far slower. While the input is
    // actively clipping we pull down faster still, enough to escape sustained
    // clipping in a second or two rather than five, but well under the JND for
    // loudness change in programme material.
    let isClipping = linearPeak >= 0.995
    let maxUp: Float = s.pointee.riseDBPerSec * dt
    let fall: Float = s.pointee.fallDBPerSec * dt
    let maxDown: Float = isClipping ? fall * s.pointee.clipRateMultiplier : fall

    let step: Float
    if delta > maxUp {
        step = maxUp
    } else if delta < -maxDown {
        step = -maxDown
    } else {
        step = delta
    }

    let lo = min(s.pointee.maxCutDB, s.pointee.maxBoostDB)
    let hi = max(s.pointee.maxCutDB, s.pointee.maxBoostDB)
    s.pointee.gainDB = max(lo, min(hi, s.pointee.gainDB + step))
    s.pointee.reportedGainDB = s.pointee.gainDB
}

// ---------------------------------------------------------------------------
// Limiter
// ---------------------------------------------------------------------------

/// Look-ahead brickwall limiter, run after the gain stage.
///
/// The detector reads each sample as it arrives, while the audio itself is held
/// back by `lookaheadSamples`. Gain reduction ramps linearly and can traverse
/// its whole range within exactly that window, so full reduction is in place by
/// the moment the offending peak emerges from the delay. That is what lets the
/// limiter catch a transient without the fast-attack distortion that a
/// zero-latency design produces.
///
/// Reduction is linked across channels, driven by whichever is loudest, so the
/// stereo image does not shift when only one side peaks.
@inline(__always)
private func autoGainLimit(_ s: UnsafeMutablePointer<AutoGainState>,
                           channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                           channelCount: Int,
                           frameCount: Int) {

    guard let delay = s.pointee.delay else { return }
    let look = Int(s.pointee.lookaheadSamples)
    guard look > 0, channelCount <= Int(s.pointee.delayChannels) else { return }

    let enabled = s.pointee.limiterEnabled != 0
    let ceiling = powf(10, s.pointee.ceilingDB / 20)

    // Gain may travel its entire range within the look-ahead window.
    let attackStep = 1.0 / Float(look)
    let release = max(0.001, s.pointee.limiterReleaseSeconds)
    let relCoef = 1 - expf(-1 / (release * s.pointee.sampleRate))

    var w = Int(s.pointee.delayWrite)
    var peakEnv = s.pointee.peakEnv
    var hold = Int(s.pointee.peakHold)
    var g = s.pointee.limGain
    var deepest: Float = 1

    for i in 0..<frameCount {

        // Linked detector: instant attack, then held for the full look-ahead
        // window before any release, so the envelope cannot relax while the
        // peak that set it is still inside the delay line.
        var a: Float = 0
        for ch in 0..<channelCount {
            guard let p = channels[ch] else { continue }
            let v = abs(p[i])
            if v > a { a = v }
        }
        if a >= peakEnv {
            peakEnv = a
            hold = look
        } else if hold > 0 {
            hold -= 1
        } else {
            peakEnv += (a - peakEnv) * relCoef
        }

        let target: Float = (enabled && peakEnv > ceiling) ? ceiling / peakEnv : 1

        if target < g {
            g = max(target, g - attackStep)
        } else {
            g += (target - g) * relCoef
        }
        if g < deepest { deepest = g }

        // Read the oldest sample, write the newest into its slot. The cursor
        // then advances, giving a delay of exactly `look` samples.
        for ch in 0..<channelCount {
            guard let p = channels[ch] else { continue }
            let slot = ch * look + w
            let out = delay[slot]
            delay[slot] = p[i]
            p[i] = out * g
        }

        w += 1
        if w >= look { w = 0 }
    }

    s.pointee.delayWrite = Int32(w)
    s.pointee.peakEnv = peakEnv
    s.pointee.peakHold = Int32(hold)
    s.pointee.limGain = g
    s.pointee.reportedLimitDB = 20 * log10f(max(deepest, 1e-6))
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Processes one buffer in place across `channelCount` non-interleaved Float32
/// channels. Real-time safe: no allocation, no locks, no ObjC or Swift dynamic
/// dispatch inside the loop.
@inline(__always)
func autoGainProcess(_ s: UnsafeMutablePointer<AutoGainState>,
                     channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                     channelCount: Int,
                     frameCount: Int) {

    let bypass = s.pointee.bypassed != 0

    // Ramp the gain across the buffer. At 0.2 dB/sec the step per buffer is
    // tiny, but interpolating costs nothing and removes any chance of a
    // discontinuity at a buffer edge.
    let startDB = s.pointee.appliedGainDB
    let endDB = bypass ? 0 : s.pointee.gainDB
    let startLin = powf(10, startDB / 20)
    let endLin = powf(10, endDB / 20)
    let increment = frameCount > 0 ? (endLin - startLin) / Float(frameCount) : 0

    var peak = s.pointee.tickPeak

    for ch in 0..<channelCount {
        guard let data = channels[ch] else { continue }
        var g = startLin
        for i in 0..<frameCount {
            let v = data[i] * g
            data[i] = v
            let a = abs(v)
            if a > peak { peak = a }
            g += increment
        }
    }

    s.pointee.tickPeak = peak
    s.pointee.appliedGainDB = endDB

    // The peak fed to the control loop is measured post-gain but PRE-limiter,
    // deliberately. If the leveller only ever saw the limited signal it would
    // never learn that it was driving into the ceiling, the limiter would work
    // continuously, and the slow transparent gain ride would be replaced by
    // permanent fast limiting. Measuring ahead of the limiter keeps the two
    // stages doing their own jobs.
    s.pointee.tickFrames += Int32(frameCount)
    if s.pointee.tickFrames >= s.pointee.framesPerTick {
        let dt = Float(s.pointee.tickFrames) / s.pointee.sampleRate
        autoGainTick(s, peak: min(s.pointee.tickPeak, 4.0), dt: dt)
        s.pointee.tickFrames = 0
        s.pointee.tickPeak = 0
    }

    autoGainLimit(s, channels: channels,
                  channelCount: channelCount,
                  frameCount: frameCount)

    // Spectrum tap, post-limiter, so the display shows what actually reaches
    // the output. Mono mix of whatever channels exist.
    if s.pointee.tapEnabled != 0, let tap = s.pointee.tap,
       s.pointee.tapCapacity > 0, channelCount > 0 {
        let cap = Int(s.pointee.tapCapacity)
        var w = Int(s.pointee.tapWrite)
        let norm = 1 / Float(channelCount)
        for i in 0..<frameCount {
            var acc: Float = 0
            for ch in 0..<channelCount {
                if let p = channels[ch] { acc += p[i] }
            }
            tap[w] = acc * norm
            w += 1
            if w >= cap { w = 0 }
        }
        s.pointee.tapWrite = Int32(w)
    }
}
