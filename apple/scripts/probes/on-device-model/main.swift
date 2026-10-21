import Foundation

extension Error {
    var publicLogShape: String { String(describing: type(of: self)) }
}

@main
struct OnDeviceModelProbe {
    static func main() async {
        let model = SystemOnDeviceLanguageModel()
        print("availability: \(model.availability)")
        guard model.availability.isAvailable else { exit(3) }
        print("contextSize: \(model.contextSize)")

        let samples = [
            ("sql", "SELECT o.id, o.total, c.name FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.total > 100;"),
            ("structure", """
            | Column | Type | Nullable | Key | Default | Comment |
            | --- | --- | --- | --- | --- | --- |
            | id | bigint | no | PK |  |  |
            | customer_id | bigint | no |  |  |  |
            | created_at | timestamp with time zone | no |  | now() |  |
            """),
            ("cjk", "注文テーブルの合計金額を顧客ごとに集計してください。")
        ]
        let baseline = await model.tokenCount(for: OnDeviceRequest(instructions: "", prompt: ""))
        for (label, text) in samples {
            let request = OnDeviceRequest(instructions: "", prompt: text)
            let tokens = await model.tokenCount(for: request) - baseline
            let characters = (text as NSString).length
            let ratio = Double(characters) / Double(max(tokens, 1))
            print("\(label): \(characters) characters, \(tokens) tokens, \(String(format: "%.2f", ratio)) per token")
        }

        let request = OnDeviceRequest(
            instructions: "You are the database assistant in TablePro. Answer briefly.",
            prompt: "Explain this SQL query.\n\n```sql\n\(samples[0].1)\n```"
        )
        let oversized = OnDeviceRequest(
            instructions: request.instructions,
            prompt: request.prompt + String(repeating: "\n| col | int | yes |  |  |  |", count: 2_000)
        )
        let fit = await model.fit([oversized, request], reservingForReply: 1_024)
        print("fit: \(fit)")
        guard case .fits(let index, let allowance) = fit, index == 1 else { exit(1) }

        var reply = ""
        do {
            for try await delta in model.streamResponse(to: request, maximumResponseTokens: min(allowance, 120)) {
                reply += delta
            }
        } catch {
            print("stream failed: \(error.localizedDescription)")
            exit(1)
        }
        print("reply: \(reply)")
        exit(reply.isEmpty ? 1 : 0)
    }
}
