import Foundation
import SQLite3

// Reads an exported Windows backup without changing the source database.
enum WindowsBackupImporter {
    static func read(url: URL, bankID: String) throws -> StudyState {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw StudyError("无法读取 Windows 备份，请从电脑版“数据与备份”重新导出。")
        }
        defer { sqlite3_close(db) }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 50_000_000)
        func rows(_ sql: String) throws -> [[String: String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StudyError("文件不是完整的华电题库学习备份。") }
            defer { sqlite3_finalize(statement) }
            var output: [[String: String]] = []; var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                var row: [String: String] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    if let value = sqlite3_column_text(statement, column) { row[name] = String(cString: value) }
                }
                output.append(row)
                guard output.count <= 100_000 else { throw StudyError("备份记录过多，请检查文件。") }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw StudyError("备份读取失败，当前记录未修改。") }
            return output
        }
        func required(_ row: [String: String], _ key: String) throws -> String {
            guard let value = row[key] else { throw StudyError("备份缺少必要字段：" + key) }; return value
        }
        func json<T: Decodable>(_ row: [String: String], _ key: String) throws -> T {
            try JSONDecoder().decode(T.self, from: Data(required(row, key).utf8))
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        func date(_ row: [String: String], _ key: String) throws -> Date {
            let raw = try required(row, key)
            guard let parsed = fractional.date(from: raw) ?? standard.date(from: raw) else { throw StudyError("备份时间格式无效。") }; return parsed
        }
        var state = StudyState(bankID: bankID)
        for row in try rows("SELECT qid,answer,correct,updated FROM practice") {
            let choices: [String] = try json(row, "answer")
            if !choices.isEmpty { state.practice[try required(row, "qid")] = SavedAnswer(choices: choices, updated: try date(row, "updated"), checked: row["correct"] != nil) }
        }
        for row in try rows("SELECT id,type,status,ordering,answers,current_q,elapsed,created,updated,submitted FROM exams") {
            guard let kind = QuestionKind(rawValue: try required(row, "type")), let status = ExamStatus(rawValue: try required(row, "status")),
                  let elapsed = Double(try required(row, "elapsed")) else { throw StudyError("备份中的考试状态无效。") }
            let order: [String] = try json(row, "ordering")
            state.exams.append(ExamRecord(id: try required(row, "id"), type: kind, status: status, order: order,
                answers: try json(row, "answers"), currentQuestion: row["current_q"] ?? order.first ?? "", elapsed: elapsed,
                created: try date(row, "created"), updated: try date(row, "updated"), submitted: row["submitted"] == nil ? nil : try date(row, "submitted")))
        }
        for row in try rows("SELECT id,source,qid,exam_id,original,review,review_correct,dismissed,created,updated FROM mistakes") {
            guard let source = MistakeSource(rawValue: try required(row, "source")), let flag = Int(try required(row, "dismissed")), [0, 1].contains(flag) else { throw StudyError("备份中的错题状态无效。") }
            state.mistakes.append(MistakeEntry(id: try required(row, "id"), source: source, qid: try required(row, "qid"), examID: row["exam_id"],
                original: try json(row, "original"), review: try json(row, "review"), dismissed: flag == 1, created: try date(row, "created"), updated: try date(row, "updated"), reviewChecked: row["review_correct"] != nil))
        }
        for row in try rows("SELECT key,value FROM settings") {
            if row["key"] == "autoRemove:practice" { state.settings.autoRemovePractice = try json(row, "value") }
            if row["key"] == "autoRemove:exam" { state.settings.autoRemoveExam = try json(row, "value") }
        }
        return state
    }
}
