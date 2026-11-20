import Foundation

/// App 内「反馈意见」→ 自家 Cloudflare Worker /feedback（永久存档 + 即时邮件通知开发者）。
/// 上传内容：用户填写的文字 + App/系统版本号 + 设备名称；
/// 若用户保留了「最后的转录」附件，还会带上该条的原始转写、优化结果和录音（界面有明示）。
public enum FeedbackService {
    public enum FeedbackError: Error, Equatable {
        case empty
        case network(String)
    }

    /// 随反馈一起发送的「最后的转录」：原始转写 + 优化结果 + 录音（可能已不存在则为 nil）。
    public struct Attachment {
        public let asrText: String
        public let polishedText: String
        public let audioData: Data?

        public init(asrText: String, polishedText: String, audioData: Data?) {
            self.asrText = asrText
            self.polishedText = polishedText
            self.audioData = audioData
        }
    }

    public struct ModelEnvironment {
        public let processingMode: String
        public let asrProvider: String
        public let asrVersion: String
        public let asrModel: String
        public let asrResourceID: String?
        public let polishProvider: String
        public let polishModel: String?

        public init(processingMode: String,
                    asrProvider: String,
                    asrVersion: String,
                    asrModel: String,
                    asrResourceID: String?,
                    polishProvider: String,
                    polishModel: String?) {
            self.processingMode = processingMode
            self.asrProvider = asrProvider
            self.asrVersion = asrVersion
            self.asrModel = asrModel
            self.asrResourceID = asrResourceID
            self.polishProvider = polishProvider
            self.polishModel = polishModel
        }

        public static func current() -> ModelEnvironment {
            let asrVersion = CloudASRTranscriber().currentVersion()
            let polish = AIPolisher.currentPolishSelection()
            return ModelEnvironment(
                processingMode: currentProcessingMode().rawValue,
                asrProvider: asrVersion.provider == .volcano ? "volcano" : "bailian",
                asrVersion: asrVersion.rawValue,
                asrModel: asrVersion.modelIdentifier,
                asrResourceID: asrVersion.resourceID.isEmpty ? nil : asrVersion.resourceID,
                polishProvider: polish.provider,
                polishModel: polish.model
            )
        }

        private static func currentProcessingMode() -> ProcessingMode {
            let group = UserDefaults(suiteName: ProcessingMode.appGroupSuiteName)
            let raw = group?.string(forKey: ProcessingMode.userDefaultsKey)
                ?? UserDefaults.standard.string(forKey: ProcessingMode.userDefaultsKey)
            let stored = raw.flatMap(ProcessingMode.init(rawValue:)) ?? .cloudOnly
            return stored == .omni ? .cloudOnly : stored
        }

        fileprivate func append(to payload: inout [String: String]) {
            payload["processing_mode"] = processingMode
            payload["asr_provider"] = asrProvider
            payload["asr_version"] = asrVersion
            payload["asr_model"] = asrModel
            if let asrResourceID, !asrResourceID.isEmpty { payload["asr_resource_id"] = asrResourceID }
            payload["polish_provider"] = polishProvider
            if let polishModel, !polishModel.isEmpty { payload["polish_model"] = polishModel }
        }
    }

    static let defaultAPIBase = "https://api.typefree.app"

    /// 录音上限（D1 单行 2MB 硬限制，留余量）。超限则只发文字、不带音频。
    public static let maxAudioBytes = 1_900_000

    /// 构造请求体（纯函数，便于测试）。空白内容返回 nil。
    public static func makePayload(message: String,
                                   appVersion: String,
                                   osVersion: String,
                                   deviceName: String = "",
                                   attachment: Attachment? = nil,
                                   modelEnvironment: ModelEnvironment? = nil) -> [String: String]? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var payload = ["message": trimmed, "app_version": appVersion, "os_version": osVersion]
        if !deviceName.isEmpty { payload["device_name"] = deviceName }
        modelEnvironment?.append(to: &payload)
        if let attachment = attachment {
            payload["asr_text"] = attachment.asrText
            payload["polished_text"] = attachment.polishedText
            if let audio = attachment.audioData, !audio.isEmpty, audio.count <= maxAudioBytes {
                payload["audio_b64"] = audio.base64EncodedString()
            }
        }
        return payload
    }

    public static func send(message: String,
                            appVersion: String,
                            deviceName: String = "",
                            attachment: Attachment? = nil,
                            modelEnvironment: ModelEnvironment? = .current(),
                            apiBase: String? = nil,
                            session: URLSession = .shared,
                            completion: @escaping (Result<Void, FeedbackError>) -> Void) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let payload = makePayload(message: message,
                                        appVersion: appVersion,
                                        osVersion: "\(os.majorVersion).\(os.minorVersion)",
                                        deviceName: deviceName,
                                        attachment: attachment,
                                        modelEnvironment: modelEnvironment) else {
            DispatchQueue.main.async { completion(.failure(.empty)) }
            return
        }
        let base = apiBase ?? UserDefaults.standard.string(forKey: "license.apiBase") ?? defaultAPIBase
        guard let url = URL(string: base + "/feedback") else {
            DispatchQueue.main.async { completion(.failure(.network("地址错误"))) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 带录音时请求体可达数 MB，给慢网络留足上传时间
        req.timeoutInterval = payload["audio_b64"] != nil ? 90 : 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        session.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    // 系统原话是英文、证书类错误里还带服务器地址：换成中文短句（体检 修4）
                    completion(.failure(.network(UserFacingError.message(for: error, fallback: "网络出错，请稍后再试"))))
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    completion(.success(()))
                } else {
                    completion(.failure(.network("提交失败（\(code)）")))
                }
            }
        }.resume()
    }
}
