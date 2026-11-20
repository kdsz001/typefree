import Foundation

/// 把错误变成给用户看的一句中文（2026-11-19 体检修4）。
///
/// 系统网络错误（URLError / NSURLErrorDomain）不是 LocalizedError，以前兜底用 "\(err)"，
/// 把一长串英文调试信息（含请求网址、试用服务器 IP）直接显示给了用户。现在：
/// - 自家错误（识别 / 润色）用它们自己的中文说明；
/// - 网络错误按错误码翻成中文短句（超时 / 没连上网 / 连接中断 / 证书问题…）；
/// - 其余认不出的，一律用调用方给的通用中文；
/// - 最后再过一道：文字里夹着网址、IP 或系统调试串的，把网址和 IP 去掉，去掉后不剩什么、或是调试串，就用通用中文。
public enum UserFacingError {

    /// 试用 / 会员通道上游出问题（池里的 Key 坏了、欠费等）时给用户的话：跟用户自己的 Key 没关系，别让他去查 Key（优5）。
    public static let hostedServiceUnavailable = "服务暂时不可用，请稍后再试"

    /// 网络层错误 → 中文短句；不是网络层错误返回 nil。
    public static func networkMessage(for error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        switch ns.code {
        case NSURLErrorTimedOut:
            return "网络超时"
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
            return "没有连上网络"
        case NSURLErrorNetworkConnectionLost:
            return "网络连接中断"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return "连不上服务器"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
             NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "网络安全校验没通过（开着代理或 VPN 时可能这样）"
        case NSURLErrorCancelled:
            // 试用 / 会员通道固定了服务器证书，指纹对不上时系统报的就是「已取消」
            return "网络连接被中断（开着代理或 VPN 时可能这样）"
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorZeroByteResource,
             NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData:
            return "服务器响应异常"
        default:
            return "网络出错"
        }
    }

    /// 任意错误 → 给用户看的一句话。fallback：认不出时用的通用中文。
    public static func message(for error: Error, fallback: String) -> String {
        let raw: String?
        if let e = error as? CloudASRTranscriber.TranscriptionError {
            raw = e.errorDescription
        } else if let e = error as? AIPolisher.PolishError {
            raw = e.errorDescription
        } else if let e = error as? NetworkFailure {
            raw = e.errorDescription
        } else {
            raw = networkMessage(for: error)
        }
        return sanitized(raw ?? fallback, fallback: fallback)
    }

    /// 网络层错误包成 NetworkFailure（errorDescription 是中文短句）；不是网络错误原样返回。
    static func wrappingNetworkError(_ error: Error) -> Error {
        if error is NetworkFailure { return error }
        return networkMessage(for: error) == nil ? error : NetworkFailure(underlying: error)
    }

    /// 去掉文字里的网址、IP；系统调试串整句换成 fallback。没夹带这些的文字原样返回（一个字都不动）。
    public static func sanitized(_ text: String, fallback: String) -> String {
        if text.contains("Error Domain=") || text.contains("NSURLErrorDomain") || text.contains("UserInfo={") {
            return fallback
        }
        var s = text
        // 网址，连同英文报错里常见的引导语（"For details, see: https://…"）
        s = s.replacingOccurrences(
            of: #"(?i)(for (more )?details?,?\s*(please\s*)?(see|refer to|visit)\s*:?\s*)?(https?|wss?)://[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]+"#,
            with: "", options: .regularExpression)
        // IPv4（可带端口）。不用 \b：中文字和数字之间不算词边界，「服务器203.0.113.7」会漏掉
        s = s.replacingOccurrences(of: #"(?<![0-9.])\d{1,3}(\.\d{1,3}){3}(:\d+)?(?![0-9])"#, with: "", options: .regularExpression)
        guard s != text else { return text }
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,:;，。：；")))
        return s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) ? s : fallback
    }
}

/// 网络层失败（断网 / 超时 / 证书等）的包装。系统网络错误不是 LocalizedError，App 里
/// `(err as? LocalizedError)?.errorDescription ?? "\(err)"` 这类写法会把整段英文调试信息显示出来；
/// 包一层后 errorDescription / localizedDescription 都是中文短句。原始错误留在 underlying，日志里 "\(err)" 照样看得到。
struct NetworkFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? { UserFacingError.networkMessage(for: underlying) ?? "网络出错" }
}
