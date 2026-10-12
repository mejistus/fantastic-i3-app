// 截图识别（../capture 调，⌥O / ⌥I）：
//   aero-helper ocr <图片>       识别里面的文字（系统自带的 Vision，不联网）：中英文、简繁，夹着日文、韩文也行，一行一行输出
//   aero-helper formula <图片>   识别里面的公式，输出 LaTeX 源码：发给 SiliconFlow 的视觉大模型。
//                                模型、提示词、参数、出错换模型和输出的清理都照 latex-ocr-queen（Raycast 扩展）。
//                                API Key 从环境变量 SILICONFLOW_API_KEY 读（../capture 从钥匙串取出来给它）
// 失败时错误信息写到 stderr，退出码 1。

import AppKit
import Vision

/// 一种语言的模型认一遍。系统一次只用排第一的语言的模型认（后面的只用来校正），所以中、日、韩要分开认
func recognize(_ image: CGImage, _ language: String) -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = language == "zh-Hans" ? ["zh-Hans", "zh-Hant", "en-US"] : [language, "en-US"]
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return request.results ?? []
}

struct TextPiece {
    var box: CGRect   // 图里的位置（0–1，原点在左下角）
    var text: String
}

func recognizeText(_ path: String) {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("读不了这张图\n".data(using: .utf8)!)
        exit(1)
    }
    // 中文模型认中英文（简繁都行），日文、韩文要各自的模型：三遍同时认，再合起来
    let languages = ["zh-Hans", "ja-JP", "ko-KR"]
    var passes = [[VNRecognizedTextObservation]](repeating: [], count: languages.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: languages.count) { i in
        let result = recognize(image, languages[i])
        lock.lock()
        passes[i] = result
        lock.unlock()
    }
    func sameLine(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.midY - b.midY) < min(a.height, b.height) / 2 }
    func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) }

    var pieces = passes[0].compactMap { o in o.topCandidates(1).first.map { TextPiece(box: o.boundingBox, text: $0.string) } }
    // 日文：有假名的一行整行用日文模型的（它也认汉字和英文），替掉中文模型在那里认出来的零碎（中文模型不认假名，常常整行漏掉）
    for o in passes[1] {
        guard let text = o.topCandidates(1).first?.string,
              text.range(of: "[\\u3041-\\u3096\\u30a1-\\u30fa\\u30fc]", options: .regularExpression) != nil else { continue }   // 假名（不算・这类标点）
        pieces.removeAll { sameLine($0.box, o.boundingBox) && overlap($0.box, o.boundingBox) > 0 }
        pieces.append(TextPiece(box: o.boundingBox, text: text))
    }
    // 韩文：有谚文的一行，中文模型没认出来的那几个词用韩文模型的（韩文模型认汉字会认错，所以中文模型认出来的部分不换）
    for o in passes[2] {
        guard let candidate = o.topCandidates(1).first,
              candidate.string.range(of: "[\\uac00-\\ud7af]", options: .regularExpression) != nil else { continue }
        let line = pieces.filter { sameLine($0.box, o.boundingBox) }
        if line.isEmpty {
            pieces.append(TextPiece(box: o.boundingBox, text: candidate.string))
            continue
        }
        let text = candidate.string
        for word in text.split(whereSeparator: \.isWhitespace) {
            guard let box = (try? candidate.boundingBox(for: word.startIndex..<word.endIndex))?.boundingBox else { continue }
            if line.allSatisfy({ overlap($0.box, box) < box.width * 0.3 }) {
                pieces.append(TextPiece(box: box, text: String(word)))
            }
        }
    }

    // 按行排：Vision 给的顺序常常是一栏一栏的（两栏的表格先出左边一整列）。从上往下，竖直方向和上一行中线
    // 相差不到半个字高的算同一行，同一行从左往右用空格连起来
    pieces.sort { $0.box.midY > $1.box.midY }
    var rows: [[TextPiece]] = []
    for piece in pieces {
        if let last = rows.last?.first, sameLine(last.box, piece.box) {
            rows[rows.count - 1].append(piece)
        } else {
            rows.append([piece])
        }
    }
    print(rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n"))
}

// MARK: - 公式（照 latex-ocr-queen）

let formulaEndpoint = "https://api.siliconflow.cn/v1/chat/completions"
let formulaModels = ["Qwen/Qwen3-VL-32B-Instruct",   // 默认的，后面三个是它报"模型不可用"（30003）或 404 时依次换的
                     "Qwen/Qwen3-VL-8B-Instruct", "Qwen/Qwen3-VL-30B-A3B-Instruct", "Qwen/Qwen2-VL-72B-Instruct"]
let formulaSystemPrompt = [
    "You are a precise LaTeX OCR engine for math formula screenshots.",
    "Return only the LaTeX source for the formula.",
    "Do not include Markdown fences, explanations, prose, or math delimiters like $...$, $$...$$, \\(...\\), or \\[...\\].",
    "Preserve multi-line structure with aligned, cases, matrix, or equation environments when needed.",
    "If the image does not contain a formula, return an empty string.",
].joined(separator: " ")
let formulaUserPrompt = "Recognize the mathematical formula in this screenshot and output only its LaTeX source."

func recognizeFormula(_ path: String) {
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        exit(1)
    }
    let environment = ProcessInfo.processInfo.environment
    guard let token = ["SILICONFLOW_API_KEY", "SILICONFLOW_API_TOKEN"].compactMap({ environment[$0] }).first(where: { !$0.isEmpty })
    else { fail("没有 SiliconFlow 的 API Key") }
    guard let image = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fail("读不了这张图") }
    let dataURL = "data:image/png;base64,\(image.base64EncodedString())"

    var errors: [String] = []
    // enable_thinking 只有默认的 32B 认，后面几个收到它会报 "does not support parameter"：那就去掉它再试一次
    models: for model in formulaModels {
      attempt: for thinkingFlag in [true, false] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": formulaSystemPrompt],
                ["role": "user", "content": [["type": "text", "text": formulaUserPrompt],
                                             ["type": "image_url", "image_url": ["url": dataURL]]]],
            ],
            "temperature": 0,
            "max_tokens": 512,
        ]
        if thinkingFlag { body["enable_thinking"] = false }
        var request = URLRequest(url: URL(string: formulaEndpoint)!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var result: (Data?, HTTPURLResponse?, Error?) = (nil, nil, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = (data, response as? HTTPURLResponse, error)
            done.signal()
        }.resume()
        done.wait()

        if let error = result.2 { fail("连不上 SiliconFlow：\(error.localizedDescription)") }
        let status = result.1?.statusCode ?? 0
        let json = result.0.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        if !(200..<300).contains(status) || json?["error"] != nil {
            let detail = json?["error"] as? [String: Any] ?? json
            let code = "\(detail?["code"] ?? "")"
            let message = detail?["message"] as? String ?? String(data: result.0 ?? Data(), encoding: .utf8)?.prefix(200).description ?? ""
            if thinkingFlag && message.contains("enable_thinking") { continue attempt }
            errors.append("\(model)：\(status) \(message)")
            if code == "30003" || status == 404 { continue models }   // 这个模型用不了，换下一个
            fail("SiliconFlow 出错：\(status) \(message)")
        }
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"]
        let content = (message as? String)
            ?? (message as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            ?? ""
        let latex = normalizeLatex(content)
        if latex.isEmpty { fail("图里没认出公式") }
        print(latex)
        return
      }
    }
    fail("模型都不可用：\(errors.joined(separator: "；"))")
}

/// 和 latex-ocr-queen 的 normalizeLatexOutput 一样：去掉思考过程、Markdown 代码块、"LaTeX:" 之类的前缀、外面的数学定界符
func normalizeLatex(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    text = text.replacingOccurrences(of: "^```(?:latex|tex|math)?\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    text = text.replacingOccurrences(of: "^(?:latex|tex|answer|result|formula)\\s*[:：]\\s*", with: "",
                                     options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    for (opening, closing) in [("\\[", "\\]"), ("\\(", "\\)"), ("$$", "$$"), ("$", "$")]
    where text.count >= opening.count + closing.count && text.hasPrefix(opening) && text.hasSuffix(closing) {
        text = String(text.dropFirst(opening.count).dropLast(closing.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}
