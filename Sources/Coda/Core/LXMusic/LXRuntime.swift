import Foundation
import JavaScriptCore
import CryptoKit
import CommonCrypto

/// One source platform an imported LX script declared at init, e.g. `tx`.
struct LXDeclaredSource: Codable, Hashable, Sendable {
    var name: String = ""
    var type: String = "music"
    var actions: [String] = []
    var qualitys: [String] = []
}

enum LXRuntimeError: LocalizedError {
    case scriptFailed(String)
    case noDeclaration
    case noHandler
    case timedOut
    case badResult

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message): return "音源脚本运行失败：\(message)"
        case .noDeclaration: return "音源没有声明支持的平台"
        case .noHandler: return "音源没有注册请求处理"
        case .timedOut: return "音源响应超时"
        case .badResult: return "音源返回了无效的结果"
        }
    }
}

/// A minimal LX Music custom-source runtime on JavaScriptCore.
///
/// The sandbox deliberately exposes only what the LX source API defines:
/// an event pair (`on`/`send`), an HTTP bridge on an ephemeral session (no
/// app cookies are shared), and small crypto/buffer utilities. A script can
/// therefore only ever see the song info the app hands it for one lookup —
/// never accounts, libraries or files.
final class LXRuntime: @unchecked Sendable {
    private(set) var declaredSources: [String: LXDeclaredSource] = [:]

    private let queue = DispatchQueue(label: "lx-source-runtime")
    private let context: JSContext
    private var requestHandler: JSValue?
    private var timers: [Int: (JSValue, DispatchWorkItem)] = [:]
    private var nextTimerID = 1

    init(script: String, scriptInfo: [String: Any]) throws {
        context = JSContext()
        var declared: [String: LXDeclaredSource] = [:]
        var loadFailure: String?
        // Setup and evaluation happen on the runtime queue; `init` blocks on
        // it once, afterwards every entry point hops onto the same queue.
        queue.sync {
            context.exceptionHandler = { _, exception in
                loadFailure = exception?.toString() ?? "unknown error"
            }
            self.installBridge(scriptInfo: scriptInfo, script: script) { sources in
                declared = sources
            }
            context.evaluateScript(script)
            if let exception = context.exception {
                loadFailure = exception.toString()
                context.exception = nil
            }
        }
        if let loadFailure { throw LXRuntimeError.scriptFailed(loadFailure) }
        guard !declared.isEmpty else { throw LXRuntimeError.noDeclaration }
        declaredSources = declared
    }

    // MARK: - Bridge installation

    private func installBridge(scriptInfo: [String: Any], script: String,
                               onDeclared: @escaping ([String: LXDeclaredSource]) -> Void) {
        let context = self.context!

        // console.* → silent sink (kept so scripts that log do not fail).
        let noop: @convention(block) () -> Void = {}
        let console = JSValue(object: [:], in: context)!
        console.setValue(noop, forProperty: "log")
        console.setValue(noop, forProperty: "warn")
        console.setValue(noop, forProperty: "error")
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        // Byte helpers shared by the native utilities.
        context.evaluateScript("""
        globalThis.__lxFromBytes = (arr) => new Uint8Array(arr);
        globalThis.__lxToBytes = (b) => {
          if (b == null) return [];
          if (Array.isArray(b)) return b;
          if (ArrayBuffer.isView(b)) return Array.from(new Uint8Array(b.buffer, b.byteOffset, b.byteLength));
          if (b instanceof ArrayBuffer) return Array.from(new Uint8Array(b));
          return [];
        };
        """)

        // on(event, handler): only the request event is kept.
        let onFn: @convention(block) (JSValue, JSValue) -> Void = { [weak self] event, handler in
            guard let self, event.toString() == "request" else { return }
            self.requestHandler = handler
        }
        context.setObject(onFn, forKeyedSubscript: "__lxOn" as NSString)

        // send(event, data): the inited declaration is captured here.
        let sendFn: @convention(block) (JSValue, JSValue) -> Void = { event, data in
            guard event.toString() == "inited",
                  let dict = data.toObject() as? [String: Any],
                  let rawSources = dict["sources"] as? [String: Any] else { return }
            var parsed: [String: LXDeclaredSource] = [:]
            for (key, value) in rawSources {
                guard let entry = value as? [String: Any] else { continue }
                parsed[key] = LXDeclaredSource(
                    name: entry["name"] as? String ?? key,
                    type: entry["type"] as? String ?? "music",
                    actions: (entry["actions"] as? [Any])?.compactMap { $0 as? String } ?? [],
                    qualitys: (entry["qualitys"] as? [Any])?.compactMap { $0 as? String } ?? [])
            }
            onDeclared(parsed)
        }
        context.setObject(sendFn, forKeyedSubscript: "__lxSend" as NSString)

        // request(url, options, callback) on an ephemeral session.
        let requestFn: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] urlValue, optionsValue, callback in
            guard let self else { return }
            let urlString = urlValue.toString() ?? ""
            let options = optionsValue.toObject() as? [String: Any] ?? [:]
            self.performRequest(urlString: urlString, options: options, callback: callback)
        }
        context.setObject(requestFn, forKeyedSubscript: "__lxRequest" as NSString)

        // Timers (JSC has none of its own).
        let setTimeoutFn: @convention(block) (JSValue, JSValue) -> Int = { [weak self] fn, ms in
            guard let self else { return 0 }
            let id = self.nextTimerID; self.nextTimerID += 1
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let entry = self.timers.removeValue(forKey: id)
                entry?.0.call(withArguments: [])
            }
            self.timers[id] = (fn, work)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(max(0, Int(ms.toInt32()))), execute: work)
            return id
        }
        context.setObject(setTimeoutFn, forKeyedSubscript: "__lxSetTimeout" as NSString)
        let clearTimeoutFn: @convention(block) (JSValue) -> Void = { [weak self] idValue in
            guard let self else { return }
            if let entry = self.timers.removeValue(forKey: Int(idValue.toInt32())) { entry.1.cancel() }
        }
        context.setObject(clearTimeoutFn, forKeyedSubscript: "__lxClearTimeout" as NSString)

        // utils.crypto.md5
        let md5Fn: @convention(block) (JSValue) -> String = { value in
            let text = value.isString ? (value.toString() ?? "") : (value.toString() ?? "")
            return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(md5Fn, forKeyedSubscript: "__lxMD5" as NSString)

        // utils.crypto.aesEncrypt(data, mode, key, iv) → Uint8Array or null.
        let aesFn: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> JSValue? = { [weak self] data, mode, key, iv in
            guard let self,
                  let cipher = Self.aesEncrypt(data: data.toString() ?? "", mode: mode.toString() ?? "",
                                               key: key.toString() ?? "", iv: iv.toString() ?? "")
            else { return nil }
            let make = self.context.evaluateScript("globalThis.__lxFromBytes")
            return make?.call(withArguments: [cipher.map { NSNumber(value: $0) }])
        }
        context.setObject(aesFn, forKeyedSubscript: "__lxAES" as NSString)

        // utils.buffer.bufToString / strToBuf
        let bufToStringFn: @convention(block) (JSValue, JSValue) -> String = { [weak self] buffer, encoding in
            guard let self else { return "" }
            let toBytes = self.context.evaluateScript("globalThis.__lxToBytes")
            let numbers = toBytes?.call(withArguments: [buffer])?.toArray() as? [NSNumber] ?? []
            let data = Data(numbers.map { $0.uint8Value })
            switch (encoding.toString() ?? "utf-8").lowercased() {
            case "hex": return data.map { String(format: "%02x", $0) }.joined()
            case "base64": return data.base64EncodedString()
            case "latin1", "binary": return String(bytes: data, encoding: .isoLatin1) ?? ""
            default: return String(decoding: data, as: UTF8.self)
            }
        }
        context.setObject(bufToStringFn, forKeyedSubscript: "__lxBufToString" as NSString)
        let strToBufFn: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] text, encoding in
            guard let self else { return nil }
            let string = text.toString() ?? ""
            let data: Data
            switch (encoding.toString() ?? "utf-8").lowercased() {
            case "hex":
                var bytes = Data(); var index = string.startIndex
                while index < string.endIndex {
                    let next = string.index(index, offsetBy: 2, limitedBy: string.endIndex) ?? string.endIndex
                    if let byte = UInt8(string[index..<next], radix: 16) { bytes.append(byte) }
                    index = next
                }
                data = bytes
            case "base64": data = Data(base64Encoded: string) ?? Data()
            default: data = Data(string.utf8)
            }
            let make = self.context.evaluateScript("globalThis.__lxFromBytes")
            return make?.call(withArguments: [data.map { NSNumber(value: $0) }])
        }
        context.setObject(strToBufFn, forKeyedSubscript: "__lxStrToBuf" as NSString)

        // Assemble the public `lx` object in JS so property shapes match the
        // real API exactly (destructuring included).
        var info = scriptInfo
        info["rawScript"] = script
        let infoValue = JSValue(object: info, in: context)!
        context.setObject(infoValue, forKeyedSubscript: "__lxScriptInfo" as NSString)
        context.evaluateScript("""
        globalThis.lx = {
          EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
          on: (event, handler) => __lxOn(event, handler),
          send: (event, data) => __lxSend(event, data),
          request: (url, options, callback) => __lxRequest(url, options || {}, callback),
          utils: {
            crypto: {
              md5: (text) => __lxMD5(text),
              aesEncrypt: (data, mode, key, iv) => __lxAES(data, mode, key, iv),
            },
            buffer: {
              bufToString: (buf, enc) => __lxBufToString(buf, enc || 'utf-8'),
              strToBuf: (str, enc) => __lxStrToBuf(str, enc || 'utf-8'),
            },
          },
          env: 'mobile',
          version: '1.2.0',
          currentScriptInfo: __lxScriptInfo,
        };
        globalThis.setTimeout = (fn, ms) => __lxSetTimeout(fn, ms || 0);
        globalThis.clearTimeout = (id) => __lxClearTimeout(id);
        """)
        if let exception = context.exception {
            loadFailureNote(exception)
            context.exception = nil
        }
    }

    private func loadFailureNote(_ exception: JSValue) {
        // Setup errors surface through the post-eval exception check in init;
        // this only keeps the exception from being swallowed silently.
        FileHandle.standardError.write(Data("LXRuntime setup: \(exception.toString() ?? "?")\n".utf8))
    }

    // MARK: - HTTP bridge

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private func performRequest(urlString: String, options: [String: Any], callback: JSValue) {
        guard let url = URL(string: urlString) else {
            queue.async { callback.call(withArguments: ["invalid url", JSValue(nullIn: self.context)!]) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String) ?? "GET"
        if let headers = options["headers"] as? [String: Any] {
            for (key, value) in headers { request.setValue("\(value)", forHTTPHeaderField: key) }
        }
        if let body = options["body"] {
            if let text = body as? String {
                request.httpBody = Data(text.utf8)
            } else if let data = try? JSONSerialization.data(withJSONObject: body) {
                request.httpBody = data
            }
        }
        if let timeoutMS = (options["timeout"] as? NSNumber)?.doubleValue, timeoutMS > 0 {
            request.timeoutInterval = timeoutMS / 1000
        }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    callback.call(withArguments: [error.localizedDescription, JSValue(nullIn: self.context)!])
                    return
                }
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                http?.allHeaderFields.forEach { headers["\($0.key)"] = "\($0.value)" }
                let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let resp: [String: Any] = [
                    "statusCode": http?.statusCode ?? 0,
                    "headers": headers,
                    "body": body,
                ]
                callback.call(withArguments: [JSValue(nullIn: self.context)!, resp])
            }
        }.resume()
    }

    // MARK: - AES (CommonCrypto)

    private static func aesEncrypt(data: String, mode: String, key: String, iv: String) -> [UInt8]? {
        let keyData = Data(key.utf8)
        guard [16, 24, 32].contains(keyData.count) else { return nil }
        let input = Data(data.utf8)
        let isECB = mode.lowercased().contains("ecb")
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                keyData.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(
                                UInt32(kCCOptionPKCS7Padding) | (isECB ? UInt32(kCCOptionECBMode) : 0)),
                            keyPtr.baseAddress, keyData.count,
                            isECB ? nil : (iv.isEmpty ? nil : iv),
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, out.count, &outLength)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength
        return [UInt8](out)
    }

    // MARK: - Calling the source

    /// Asks the active handler for a stream URL, per the LX `musicUrl` action.
    func musicURL(source: String, musicInfo: [String: Any], type: String) async throws -> String {
        guard let handler = queue.sync(execute: { requestHandler }) else { throw LXRuntimeError.noHandler }
        let payload: [String: Any] = [
            "action": "musicUrl",
            "source": source,
            "info": ["musicInfo": musicInfo, "type": type],
        ]
        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            queue.async {
                guard let argument = JSValue(object: payload, in: self.context) else {
                    box.resume(throwing: LXRuntimeError.badResult); return
                }
                let result = handler.call(withArguments: [argument])
                if let exception = self.context.exception {
                    self.context.exception = nil
                    box.resume(throwing: LXRuntimeError.scriptFailed(exception.toString() ?? "error"))
                    return
                }
                guard let result else { box.resume(throwing: LXRuntimeError.badResult); return }
                if result.isObject, result.hasProperty("then") {
                    let onOK: @convention(block) (JSValue) -> Void = { value in
                        if let url = value.toString(), !url.isEmpty, url != "undefined" {
                            box.resume(returning: url)
                        } else { box.resume(throwing: LXRuntimeError.badResult) }
                    }
                    let onErr: @convention(block) (JSValue) -> Void = { error in
                        box.resume(throwing: LXRuntimeError.scriptFailed(error.toString() ?? "rejected"))
                    }
                    result.invokeMethod("then", withArguments: [
                        JSValue(object: onOK, in: self.context) as Any,
                        JSValue(object: onErr, in: self.context) as Any,
                    ])
                } else if let url = result.toString(), !url.isEmpty {
                    box.resume(returning: url)
                } else {
                    box.resume(throwing: LXRuntimeError.badResult)
                }
            }
            queue.asyncAfter(deadline: .now() + 12) {
                box.resume(throwing: LXRuntimeError.timedOut)
            }
        }
    }
}

/// Resumes a continuation exactly once, from whichever callback lands first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func resume(returning value: String) {
        lock.lock(); let target = continuation; continuation = nil; lock.unlock()
        target?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock(); let target = continuation; continuation = nil; lock.unlock()
        target?.resume(throwing: error)
    }
}
