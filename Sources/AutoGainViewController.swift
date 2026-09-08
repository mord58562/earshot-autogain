import Accelerate
import AppKit
import AVFoundation
import CoreAudioKit
import QuartzCore

/// A quiet bar spectrum. Bars rise instantly and decay smoothly, drawn with
/// the accent colour over a faint track, no labels, no grid: the point is a
/// glance at the shape of what is playing, not measurement.
final class SpectrumView: NSView {

    var values: [Float] = [] {
        didSet { needsDisplay = true }
    }

    /// Display floor in dB. Anything at or below draws as an empty bar.
    let floorDB: Float = -78

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        guard !values.isEmpty else { return }
        let inset: CGFloat = 3
        let usable = bounds.insetBy(dx: inset, dy: inset)
        let n = CGFloat(values.count)
        let gap: CGFloat = 1
        let barWidth = max(1, (usable.width - gap * (n - 1)) / n)

        NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
        var x = usable.minX
        for v in values {
            let fraction = CGFloat(max(0, min(1, (v - floorDB) / -floorDB)))
            let h = usable.height * fraction
            if h >= 0.5 {
                NSRect(x: x, y: usable.maxY - h, width: barWidth, height: h)
                    .fill()
            }
            x += barWidth + gap
        }
    }
}

/// The extension's principal class. Named explicitly with `@objc` so the
/// `NSExtensionPrincipalClass` entry in Info.plist does not have to carry a
/// Swift-mangled module prefix.
@objc(AutoGainViewController)
public final class AutoGainViewController: AUViewController, AUAudioUnitFactory {

    private var audioUnit: AutoGainAudioUnit?
    private var observers: [AUParameterObserverToken] = []
    private var meterTimer: Timer?

    private let gainReadout = NSTextField(labelWithString: "0.0 dB")
    /// Tiny indicator dot for limiter activity. Invisible when idle; fades in
    /// softly while the limiter is reducing and lingers briefly afterwards so
    /// isolated transient catches register as a glow rather than a strobe.
    private let limitDot = NSView()
    private var limitLastActive: CFTimeInterval = 0

    // MARK: Spectrum analysis state
    private let spectrumView = SpectrumView()
    private let fftSize = Int(kSpectrumTapSamples)
    private let bandCount = 44
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var sampleBuf = [Float]()
    private var realBuf = [Float]()
    private var imagBuf = [Float]()
    private var magsDB = [Float]()
    private var smoothed = [Float]()
    private var bandEdges = [Float]()
    private var edgesForRate: Float = 0
    private let meterBar = NSView()
    private var meterWidth: NSLayoutConstraint!
    private var rows: [AUParameterAddress: NSSlider] = [:]
    private var valueLabels: [AUParameterAddress: NSTextField] = [:]

    // MARK: AUAudioUnitFactory

    public func createAudioUnit(with componentDescription: AudioComponentDescription)
        throws -> AUAudioUnit {
        let unit = try AutoGainAudioUnit(componentDescription: componentDescription,
                                         options: [])
        audioUnit = unit
        DispatchQueue.main.async { [weak self] in self?.connectUI() }
        return unit
    }

    // MARK: View

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 508))
        view.wantsLayer = true
        buildUI()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        connectUI()
        prepareSpectrum()
        audioUnit?.setSpectrumTap(true)
        startMeter()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        audioUnit?.setSpectrumTap(false)
        meterTimer?.invalidate()
        meterTimer = nil
    }

    deinit {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    // MARK: Spectrum

    private func prepareSpectrum() {
        guard fftSetup == nil else { return }
        let log2n = vDSP_Length(round(log2(Double(fftSize))))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        sampleBuf = [Float](repeating: 0, count: fftSize)
        realBuf = [Float](repeating: 0, count: fftSize / 2)
        imagBuf = [Float](repeating: 0, count: fftSize / 2)
        magsDB = [Float](repeating: 0, count: fftSize / 2)
        smoothed = [Float](repeating: spectrumView.floorDB, count: bandCount)
    }

    private func rebuildEdgesIfNeeded(rate: Float) {
        guard rate > 0, rate != edgesForRate else { return }
        edgesForRate = rate
        let lo: Float = 25
        let hi: Float = min(18_000, rate / 2 * 0.95)
        bandEdges = (0...bandCount).map { i in
            lo * powf(hi / lo, Float(i) / Float(bandCount))
        }
    }

    private func updateSpectrum(_ unit: AutoGainAudioUnit) {
        guard let setup = fftSetup else { return }
        let rate = unit.currentSampleRate
        rebuildEdgesIfNeeded(rate: rate)
        guard !bandEdges.isEmpty else { return }

        let ok = sampleBuf.withUnsafeMutableBufferPointer { buf in
            unit.copySpectrum(into: buf.baseAddress!, count: fftSize)
        }
        guard ok else { return }

        vDSP_vmul(sampleBuf, 1, window, 1, &sampleBuf, 1, vDSP_Length(fftSize))

        let log2n = vDSP_Length(round(log2(Double(fftSize))))
        realBuf.withUnsafeMutableBufferPointer { re in
            imagBuf.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!,
                                            imagp: im.baseAddress!)
                sampleBuf.withUnsafeBufferPointer { raw in
                    raw.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                       capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magsDB, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Calibrate so a full-scale sine reads 0 dB: amp = 2|X| / (N * cg),
        // Hann coherent gain cg = 0.5, and zrip output carries a factor of 2,
        // giving amp = |X| / (N / 2) before that factor. Folded into one scale.
        var scale = 2 / (Float(fftSize) * 0.5 * 2)
        vDSP_vsmul(magsDB, 1, &scale, &magsDB, 1, vDSP_Length(fftSize / 2))
        var floorLin: Float = 1e-9
        vDSP_vthr(magsDB, 1, &floorLin, &magsDB, 1, vDSP_Length(fftSize / 2))
        var one: Float = 1
        vDSP_vdbcon(magsDB, 1, &one, &magsDB, 1,
                    vDSP_Length(fftSize / 2), 1)

        // Log-spaced band maxima. A band narrower than one FFT bin at the low
        // end takes the nearest bin rather than drawing a hole.
        let binHz = rate / Float(fftSize)
        for b in 0..<bandCount {
            var lo = Int(bandEdges[b] / binHz)
            var hi = Int(bandEdges[b + 1] / binHz)
            lo = max(1, min(lo, fftSize / 2 - 1))
            hi = max(lo, min(hi, fftSize / 2 - 1))
            var peak: Float = -160
            for i in lo...hi where magsDB[i] > peak { peak = magsDB[i] }
            // Instant rise, smooth fall.
            if peak > smoothed[b] {
                smoothed[b] = peak
            } else {
                smoothed[b] += (peak - smoothed[b]) * 0.25
            }
        }
        spectrumView.values = smoothed
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Earshot AutoGain")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        // Gain reduction meter. Fills leftward from unity as gain is pulled down.
        let meterTrack = NSView()
        meterTrack.wantsLayer = true
        meterTrack.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        meterTrack.layer?.cornerRadius = 3
        meterTrack.translatesAutoresizingMaskIntoConstraints = false
        meterTrack.heightAnchor.constraint(equalToConstant: 6).isActive = true

        meterBar.wantsLayer = true
        meterBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        meterBar.layer?.cornerRadius = 3
        meterBar.translatesAutoresizingMaskIntoConstraints = false
        meterTrack.addSubview(meterBar)
        meterWidth = meterBar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            meterBar.leadingAnchor.constraint(equalTo: meterTrack.leadingAnchor),
            meterBar.topAnchor.constraint(equalTo: meterTrack.topAnchor),
            meterBar.bottomAnchor.constraint(equalTo: meterTrack.bottomAnchor),
            meterWidth
        ])

        gainReadout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        gainReadout.alignment = .right

        let meterRow = NSStackView(views: [meterTrack, gainReadout])
        meterRow.orientation = .horizontal
        meterRow.spacing = 10
        gainReadout.widthAnchor.constraint(equalToConstant: 66).isActive = true

        limitDot.wantsLayer = true
        limitDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        limitDot.layer?.cornerRadius = 3
        limitDot.layer?.opacity = 0
        limitDot.translatesAutoresizingMaskIntoConstraints = false
        limitDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        limitDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        limitDot.toolTip = "Limiter activity"
        meterRow.addArrangedSubview(limitDot)

        let reseed = NSButton(title: "Reseed", target: self,
                              action: #selector(reseedPressed))
        reseed.bezelStyle = .accessoryBarAction
        reseed.controlSize = .small
        reseed.font = .systemFont(ofSize: 10)
        reseed.toolTip = "Snap gain to the current level instead of waiting "
            + "for the slow rise. Use after switching to a quieter source."
        meterRow.addArrangedSubview(reseed)

        spectrumView.translatesAutoresizingMaskIntoConstraints = false
        spectrumView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let stack = NSStackView(views: [title, meterRow, spectrumView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            meterRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            spectrumView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        controlStack = stack
    }

    private var controlStack: NSStackView!

    private func connectUI() {
        // The host may create the audio unit before it ever requests the view,
        // in which case controlStack does not exist yet. Touching .view forces
        // loadView; the rows guard makes a second call from viewDidAppear a
        // no-op rather than a duplicate set of sliders.
        _ = self.view
        guard rows.isEmpty, let tree = audioUnit?.parameterTree else { return }

        for parameter in tree.allParameters {
            let label = NSTextField(labelWithString: parameter.displayName)
            label.font = .systemFont(ofSize: 11)
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let slider = NSSlider(value: Double(parameter.value),
                                  minValue: Double(parameter.minValue),
                                  maxValue: Double(parameter.maxValue),
                                  target: self,
                                  action: #selector(sliderChanged(_:)))
            slider.tag = Int(parameter.address)

            let value = NSTextField(labelWithString: parameter.string(fromValue: nil))
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.alignment = .right
            value.textColor = .secondaryLabelColor
            value.widthAnchor.constraint(equalToConstant: 68).isActive = true

            let row = NSStackView(views: [label, slider, value])
            row.orientation = .horizontal
            row.spacing = 8
            controlStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: controlStack.widthAnchor).isActive = true

            rows[parameter.address] = slider
            valueLabels[parameter.address] = value
        }

        // Reflect host-side automation and preset loads back into the sliders.
        let token = tree.token(byAddingParameterObserver: { [weak self] address, value in
            DispatchQueue.main.async {
                self?.rows[address]?.doubleValue = Double(value)
                if let p = tree.parameter(withAddress: address) {
                    self?.valueLabels[address]?.stringValue = p.string(fromValue: nil)
                }
            }
        })
        observers.append(token)
    }

    @objc private func reseedPressed() {
        audioUnit?.requestReseed()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let tree = audioUnit?.parameterTree,
              let parameter = tree.parameter(withAddress: AUParameterAddress(sender.tag))
        else { return }
        parameter.value = AUValue(sender.doubleValue)
        valueLabels[parameter.address]?.stringValue = parameter.string(fromValue: nil)
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0,
                                          repeats: true) { [weak self] _ in
            guard let self = self, let unit = self.audioUnit else { return }
            let gain = unit.currentGainDB
            self.gainReadout.stringValue = String(format: "%+.2f dB", gain)
            // Full scale on the meter is 24 dB of reduction.
            let fraction = CGFloat(min(1, max(0, -gain / 24)))
            self.meterWidth.constant = fraction * (self.view.bounds.width - 36 - 76)

            // Limiter indicator. The limiter should sit idle if the leveller
            // is doing its job, so this stays a quiet diagnostic: a small dot
            // that glows during reduction and fades over a second afterwards.
            // Opacity is written directly rather than via text or colour
            // changes so nothing in the layout ever moves or reflows.
            let reduction = unit.currentLimitDB
            let now = CACurrentMediaTime()
            if reduction < -0.05 {
                self.limitLastActive = now
                self.limitDot.toolTip =
                    String(format: "Limiter %.1f dB", reduction)
            }
            let sinceActive = now - self.limitLastActive
            let opacity = Float(max(0, min(1, 1 - sinceActive / 1.0)))
            if self.limitDot.layer?.opacity != opacity {
                self.limitDot.layer?.opacity = opacity
            }
            if sinceActive > 1.0 {
                self.limitDot.toolTip = "Limiter idle"
            }

            self.updateSpectrum(unit)
        }
    }
}
