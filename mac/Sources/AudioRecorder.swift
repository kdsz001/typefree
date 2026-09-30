import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

class AudioRecorder {
    private var engine: AVAudioEngine?
    private var inputAudioUnit: AudioUnit?
    private var auhalFormat: AVAudioFormat?
    private var levelCallback: ((Float) -> Void)?
    private var rawBuffers: [AVAudioPCMBuffer] = []
    private let bufferQueue = DispatchQueue(label: "audio.buffer")
    private var isCapturing = false
    private var engineReady = false
    private var hasRegisteredConfigObserver = false
    private var needsEngineRebuild = true
    private var isReconfiguringEngine = false

    /// Call at app launch to register for route/config changes.
    func prepare() {
        guard !hasRegisteredConfigObserver else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMicrophoneSelectionChange),
            name: .voicePolishMicrophoneSelectionDidChange,
            object: nil
        )
        hasRegisteredConfigObserver = true
        // 不在这里预建引擎：空闲时持有 inputNode 会让进程挂在系统的
        // CADefaultDeviceAggregate 上，macOS 26 在默认设备切换重建它时会崩（系统 bug）。
        // 每次 startRecording 本就强制全量重建引擎，预热没有速度收益。
    }

    @objc private func handleMicrophoneSelectionChange() {
        NSLog("[AudioRecorder] Microphone selection changed, rebuilding engine")
        engineReady = false
        needsEngineRebuild = true
        let shouldResume = isCapturing
        if engine?.isRunning == true { engine?.stop() }
        guard shouldResume else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isCapturing else { return }
            do {
                try self.restartCapture()
            } catch {
                NSLog("[AudioRecorder] Failed to restart after microphone change: %@", error.localizedDescription)
            }
        }
    }

    private func configureEngineIfNeeded(force: Bool = false) {
        guard force || engine == nil || needsEngineRebuild else { return }

        isReconfiguringEngine = true
        defer { isReconfiguringEngine = false }

        teardownEngine()

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        applySelectedInputDevice(to: inputNode)

        // engine.prepare() 强制 AUHAL 提交设备切换并完成格式协商。
        // 没有这一步，inputNode.outputFormat 可能仍是切换前设备的格式（iPhone 接力场景）。
        engine.prepare()

        // prepare 之后再轮询等格式稳定（最多 300ms）。iPhone 接力首次激活有 ~50-200ms 延迟。
        let nativeFormat = waitForStableInputFormat(inputNode: inputNode, timeoutMs: 300)
        NSLog("[AudioRecorder] Native format: sampleRate=%.0f channels=%d", nativeFormat.sampleRate, nativeFormat.channelCount)

        guard nativeFormat.channelCount > 0 else {
            NSLog("[AudioRecorder] ERROR: No input channels!")
            return
        }

        // Keep a prepared tap around so starting a recording does not rebuild the whole graph.
        // 关键：传 nil 让 AVAudioEngine 用 bus 的真实格式（避免我们传的 format 跟实际数据不匹配，导致 tap 不回调）。
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self = self, self.isCapturing else { return }

            // Store buffer copy
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }
            self.bufferQueue.async {
                self.rawBuffers.append(copy)
            }

            // Audio level for visualization
            if let channelData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var rms: Float = 0
                for i in 0..<count {
                    let sample = channelData[0][i]
                    rms += sample * sample
                }
                rms = sqrt(rms / max(Float(count), 1))
                // Use peak amplitude for punchy visualization
                var peak: Float = 0
                for i in 0..<count {
                    let v = Swift.abs(channelData[0][i])
                    if v > peak { peak = v }
                }
                let level = min(max(peak * 6.0, rms * 15.0), 1.0)
                self.levelCallback?(level)
            }
        }

        engineReady = true
        needsEngineRebuild = false
        NSLog("[AudioRecorder] Engine prepared")
    }

    @objc private func handleConfigChange(_ notification: Notification) {
        guard !isReconfiguringEngine else {
            NSLog("[AudioRecorder] Config change during engine rebuild ignored")
            return
        }
        NSLog("[AudioRecorder] Config change detected")
        engineReady = false
        needsEngineRebuild = true
        let shouldResumeCapture = isCapturing

        if engine?.isRunning == true {
            engine?.stop()
        }

        guard shouldResumeCapture else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isCapturing else { return }
            do {
                try self.restartCapture()
                NSLog("[AudioRecorder] Capture restarted after config change")
            } catch {
                NSLog("[AudioRecorder] Failed to restart after config change: %@", error.localizedDescription)
            }
        }
    }

    /// 录音中途重建采集：按当前的麦克风选择走 AVAudioEngine 或 AUHAL，并先停掉另一条，
    /// 否则两路同时往 rawBuffers 里写，音频会交错成乱码（选了指定麦克风、录音中拔掉它时会发生）。
    private func restartCapture() throws {
        if MicrophoneManager.shared.selectedUID == MicrophoneManager.systemDefaultUID {
            stopAUHAL()
            try startEngineIfNeeded()
        } else {
            teardownEngine()
            stopAUHAL()
            try startAUHAL()
        }
    }

    /// 返回 nil 表示成功，非 nil 为错误信息
    func startRecording(levelUpdate: @escaping (Float) -> Void) -> String? {
        NotificationCenter.default.post(name: .voicePolishRecordingWillStart, object: self)
        engineReady = false
        needsEngineRebuild = true

        prepare()
        levelCallback = levelUpdate
        bufferQueue.sync {
            self.rawBuffers.removeAll(keepingCapacity: true)
        }
        isCapturing = true
        do {
            if MicrophoneManager.shared.selectedUID == MicrophoneManager.systemDefaultUID {
                try startEngineIfNeeded()
                NSLog("[AudioRecorder] Capturing started with system default AVAudioEngine")
            } else {
                teardownEngine()
                try startAUHAL()
                NSLog("[AudioRecorder] Capturing started with selected-device AUHAL")
            }
            return nil  // 成功
        } catch {
            isCapturing = false
            levelCallback = nil
            teardownEngine()
            stopAUHAL()
            let msg = error.localizedDescription
            NSLog("[AudioRecorder] Failed to start recording: %@", msg)
            return msg
        }
    }

    func stopRecording(completion: @escaping ([Float]?) -> Void) {
        stopCapture()
        NSLog("[AudioRecorder] Capturing stopped")

        let capturedBuffers = bufferQueue.sync { () -> [AVAudioPCMBuffer] in
            let captured = self.rawBuffers
            self.rawBuffers.removeAll(keepingCapacity: true)
            return captured
        }

        NSLog("[AudioRecorder] Captured %d buffers", capturedBuffers.count)
        processBuffers(capturedBuffers, completion: completion)
    }

    func cancelRecording() {
        stopCapture()
        bufferQueue.sync {
            self.rawBuffers.removeAll(keepingCapacity: true)
        }
        NSLog("[AudioRecorder] Capturing canceled")
    }

    /// 轮询直到输入格式稳定（channelCount > 0 且 sampleRate > 0），最多等 timeoutMs。
    /// iPhone Continuity 等热设备需要 50-200ms 才能完成格式协商。
    private func waitForStableInputFormat(inputNode: AVAudioInputNode, timeoutMs: Int) -> AVAudioFormat {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var lastFormat = inputNode.outputFormat(forBus: 0)
        repeat {
            let format = inputNode.outputFormat(forBus: 0)
            if format.channelCount > 0 && format.sampleRate > 0 {
                lastFormat = format
                return format
            }
            usleep(20_000) // 20ms
        } while Date() < deadline
        NSLog("[AudioRecorder] WARNING: format never stabilized, falling back to last seen")
        return lastFormat
    }

    private func applySelectedInputDevice(to inputNode: AVAudioInputNode) {
        let mgr = MicrophoneManager.shared
        // 跟随系统默认时不需要显式设置（保持 AUHAL 默认行为）
        guard mgr.selectedUID != MicrophoneManager.systemDefaultUID else {
            NSLog("[AudioRecorder] Following system default input")
            return
        }
        guard var deviceID = mgr.resolvedDeviceID else {
            NSLog("[AudioRecorder] Selected device not resolved, falling back to system default")
            return
        }
        guard let audioUnit = inputNode.audioUnit else {
            NSLog("[AudioRecorder] inputNode.audioUnit is nil, cannot set device (will use default)")
            return
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            NSLog("[AudioRecorder] Set input device to ID=%d (uid=%@)", Int(deviceID), mgr.selectedUID)
        } else {
            NSLog("[AudioRecorder] Failed to set input device, status=%d (will use default)", Int(status))
        }
    }

    private func teardownEngine() {
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        engineReady = false
    }

    private func stopCapture() {
        isCapturing = false
        levelCallback = nil
        // 停止后释放引擎，空闲时不挂在系统聚合设备上（见 prepare 内注释）
        teardownEngine()
        stopAUHAL()
    }

    private func startEngineIfNeeded() throws {
        configureEngineIfNeeded(force: needsEngineRebuild)

        guard let engine = engine, engineReady else {
            throw RecorderError.engineUnavailable
        }

        if !engine.isRunning {
            try engine.start()
            NSLog("[AudioRecorder] Engine started")
        }
    }

    private func startAUHAL() throws {
        stopAUHAL()

        guard var deviceID = MicrophoneManager.shared.resolvedDeviceID else {
            throw RecorderError.selectedDeviceUnavailable
        }

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw RecorderError.audioUnitFailure("HALOutput component not found")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        try check(status, "AudioComponentInstanceNew")
        guard let unit else {
            throw RecorderError.audioUnitFailure("AudioComponentInstanceNew returned nil")
        }

        do {
            var enableInput: UInt32 = 1
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableInput,
                UInt32(MemoryLayout<UInt32>.size)
            )
            try check(status, "Enable AUHAL input")

            var disableOutput: UInt32 = 0
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableOutput,
                UInt32(MemoryLayout<UInt32>.size)
            )
            try check(status, "Disable AUHAL output")

            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            try check(status, "Set AUHAL input device")

            let sampleRate = nominalSampleRate(for: deviceID) ?? 48_000
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw RecorderError.audioUnitFailure("Unable to create AUHAL client format")
            }
            auhalFormat = format
            var streamDescription = format.streamDescription.pointee
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &streamDescription,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            try check(status, "Set AUHAL stream format")

            var callback = AURenderCallbackStruct(
                inputProc: AudioRecorder.auhalRenderCallback,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            try check(status, "Set AUHAL input callback")

            status = AudioUnitInitialize(unit)
            try check(status, "AudioUnitInitialize")

            inputAudioUnit = unit
            status = AudioOutputUnitStart(unit)
            try check(status, "AudioOutputUnitStart")
            NSLog("[AudioRecorder] AUHAL started on device ID=%d, sampleRate=%.0f", Int(deviceID), sampleRate)
        } catch {
            AudioComponentInstanceDispose(unit)
            auhalFormat = nil
            throw error
        }
    }

    private static let auhalRenderCallback: AURenderCallback = { refCon, flags, timestamp, _, frameCount, _ in
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue()
        return recorder.renderAUHALInput(flags: flags, timestamp: timestamp, frameCount: frameCount)
    }

    private func renderAUHALInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard isCapturing, let unit = inputAudioUnit, let format = auhalFormat else { return noErr }

        let byteCount = Int(frameCount) * MemoryLayout<Float>.size
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
        defer { data.deallocate() }

        let audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteCount),
            mData: data
        )
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, &bufferList)
        guard status == noErr else { return status }

        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let dst = copy.floatChannelData else {
            return noErr
        }
        copy.frameLength = frameCount
        let src = data.assumingMemoryBound(to: Float.self)
        memcpy(dst[0], src, byteCount)

        bufferQueue.async {
            self.rawBuffers.append(copy)
        }

        var rms: Float = 0
        var peak: Float = 0
        let count = Int(frameCount)
        for i in 0..<count {
            let sample = src[i]
            rms += sample * sample
            let v = Swift.abs(sample)
            if v > peak { peak = v }
        }
        rms = sqrt(rms / max(Float(count), 1))
        let level = min(max(peak * 6.0, rms * 15.0), 1.0)
        levelCallback?(level)

        return noErr
    }

    private func stopAUHAL() {
        guard let unit = inputAudioUnit else {
            auhalFormat = nil
            return
        }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        inputAudioUnit = nil
        auhalFormat = nil
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw RecorderError.audioUnitFailure("\(operation) failed (\(status))")
        }
    }

    private func processBuffers(_ capturedBuffers: [AVAudioPCMBuffer], completion: @escaping ([Float]?) -> Void) {
        let start = Date()
        let allSamples = convertToSamples(capturedBuffers)
        NSLog("[AudioRecorder] Total converted: %d samples (%.1f sec)", allSamples.count, Float(allSamples.count) / 16000.0)
        NSLog("[AudioRecorder] Buffer conversion took %.0f ms", Date().timeIntervalSince(start) * 1000)
        completion(allSamples.isEmpty ? nil : allSamples)
    }

    /// 录音进行中：非破坏性地把「到目前为止」已捕获的音频转成 16kHz 单声道样本（供边录边发用）。
    /// 只快照缓冲区数组（浅拷贝引用）后转换，不清空、不影响持续捕获。
    func snapshotSamples() -> [Float] {
        let snapshot = bufferQueue.sync { self.rawBuffers }
        return convertToSamples(snapshot)
    }

    /// 把一组捕获缓冲（可能跨格式，设备切换时会变）统一转成 16kHz 单声道 Float32。
    private func convertToSamples(_ capturedBuffers: [AVAudioPCMBuffer]) -> [Float] {
        guard !capturedBuffers.isEmpty else { return [] }

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: false)!

        // Group buffers by format (may differ after config change)
        var allSamples: [Float] = []
        var currentFormat: AVAudioFormat? = nil
        var currentBuffers: [AVAudioPCMBuffer] = []

        for buf in capturedBuffers {
            if currentFormat == nil || buf.format == currentFormat! {
                currentFormat = buf.format
                currentBuffers.append(buf)
            } else {
                if let converted = convertBuffers(currentBuffers, from: currentFormat!, to: outputFormat) {
                    allSamples.append(contentsOf: converted)
                }
                currentFormat = buf.format
                currentBuffers = [buf]
            }
        }
        if !currentBuffers.isEmpty, let fmt = currentFormat {
            if let converted = convertBuffers(currentBuffers, from: fmt, to: outputFormat) {
                allSamples.append(contentsOf: converted)
            }
        }
        return allSamples
    }

    private func convertBuffers(_ buffers: [AVAudioPCMBuffer], from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> [Float]? {
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0 else { return nil }

        guard let merged = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else { return nil }
        merged.frameLength = AVAudioFrameCount(totalFrames)

        var offset = 0
        for buf in buffers {
            let frames = Int(buf.frameLength)
            if let src = buf.floatChannelData, let dst = merged.floatChannelData {
                for ch in 0..<Int(inputFormat.channelCount) {
                    memcpy(dst[ch].advanced(by: offset), src[ch], frames * MemoryLayout<Float>.size)
                }
            }
            offset += frames
        }

        if inputFormat.sampleRate == outputFormat.sampleRate && inputFormat.channelCount == outputFormat.channelCount {
            guard let data = merged.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: totalFrames))
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        let outputFrameCount = AVAudioFrameCount(Double(totalFrames) * outputFormat.sampleRate / inputFormat.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return nil }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return merged
        }

        if let error = error {
            NSLog("[AudioRecorder] Conversion error: %@", error.localizedDescription)
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopAUHAL()
        teardownEngine()
    }

    enum RecorderError: Error {
        case engineUnavailable
        case selectedDeviceUnavailable
        case audioUnitFailure(String)
    }
}

extension AudioRecorder.RecorderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "Audio engine unavailable"
        case .selectedDeviceUnavailable:
            return "Selected microphone is unavailable"
        case .audioUnitFailure(let message):
            return message
        }
    }
}
