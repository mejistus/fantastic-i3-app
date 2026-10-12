// 截图识别（../capture 调，⌥O / ⌥I）：
//   aero-helper ocr <图片>       识别里面的文字（系统自带的 Vision，中英文，不联网），一行一行输出
//   aero-helper formula <图片>   识别里面的公式，输出 LaTeX 源码：发给 SiliconFlow 的视觉大模型。
//                                模型、提示词、参数、出错换模型和输出的清理都照 latex-ocr-queen（Raycast 扩展）。
//                                API Key 从环境变量 SILICONFLOW_API_KEY 读（../capture 从钥匙串取出来给它）
// 失败时错误信息写到 stderr，退出码 1。

import AppKit
import Vision

func recognizeText(_ path: String) {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("读不了这张图\n".data(using: .utf8)!)
        exit(1)
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.automaticallyDetectsLanguage = true
    do {
        try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
        FileHandle.standardError.write("文字识别失败：\(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    // 按行排：Vision 给的顺序常常是一栏一栏的（两栏的表格先出左边一整列）。从上往下，竖直方向和上一行中线
    // 相差不到半个字高的算同一行，同一行从左往右用空格连起来
    let pieces = (request.results ?? []).compactMap { observation -> (box: CGRect, text: String)? in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        return (observation.boundingBox, text)
    }.sorted { $0.box.midY > $1.box.midY }   // 坐标原点在左下角
    var rows: [[(box: CGRect, text: String)]] = []
    for piece in pieces {
        if let last = rows.last?.first, abs(last.box.midY - piece.box.midY) < min(last.box.height, piece.box.height) / 2 {
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
    for model in formulaModels {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": formulaSystemPrompt],
                ["role": "user", "content": [["type": "text", "text": formulaUserPrompt],
                                             ["type": "image_url", "image_url": ["url": dataURL]]]],
            ],
            "temperature": 0,
            "max_tokens": 512,
            "enable_thinking": false,
        ]
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
            errors.append("\(model)：\(status) \(message)")
            if code == "30003" || status == 404 { continue }   // 这个模型用不了，换下一个
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
