import Foundation

@main struct TextWorkbenchChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        check(TextWorkbench.detect("{\"name\":\"方寸\"}") == .json, "JSON detection")
        check(TextWorkbench.detect("1700000000000") == .timestamp, "Milliseconds detection")
        check(TextWorkbench.detect("invoice 1700000000") == .basic, "Do not guess embedded numbers")
        let pretty = try TextWorkbench.json("{\"b\":2,\"a\":1}", operation: .format)
        check(pretty.contains("\n"), "Readable JSON")
        check(try TextWorkbench.json(pretty, operation: .compact) == "{\"b\":2,\"a\":1}", "Compact preserves key order")
        let large = "{\"id\":12345678901234567890123456789012345678901234567890}"
        check(try TextWorkbench.json(large, operation: .compact) == large, "Never round identifiers")
        for invalid in ["{\"a\":1,}", "[1,]"] {
            do { _ = try TextWorkbench.json(invalid, operation: .format); fatalError("Trailing comma accepted") } catch {}
        }
        for invalid in ["01", "+1", "NaN", "[true false]", "{\"a\":}", "{\"a\":1} garbage", "\"bad\nstring\""] {
            do { _ = try TextWorkbench.json(invalid, operation: .format); fatalError("Invalid JSON accepted: \(invalid)") } catch {}
        }
        check(try TextWorkbench.json("{\r\n\"a\": [true, null, {}]\r\n}", operation: .compact) == "{\"a\":[true,null,{}]}", "CRLF JSON")
        check(try TextWorkbench.json("1e999", operation: .format) == "1e999", "Preserve arbitrary numeric lexemes")
        for i in 0..<30 {
            let fixture: [String: Any] = ["number": i, "nested": [true, false], "name": "方寸\n\" \(i)"]
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: fixture), as: UTF8.self)
            let formatted = try TextWorkbench.json(encoded, operation: .format)
            let decoded = try JSONSerialization.jsonObject(with: Data(formatted.utf8)) as! NSDictionary
            check(decoded == fixture as NSDictionary, "Formatted JSON preserves semantic data")
        }
        let combining = "\"" + "\u{0301}" + "a,b\""
        check(try TextWorkbench.json(combining, operation: .compact) == combining, "Combining marks in strings")
        let original = "中文\n\"hello\"\\path"
        let escaped = try TextWorkbench.json(original, operation: .escape)
        check(try TextWorkbench.json(escaped, operation: .unescape) == original, "JSON string roundtrip")
        do { _ = try TextWorkbench.json("{oops}", operation: .format); fatalError("Invalid JSON accepted") } catch {}
        check(try TextWorkbench.timestamp("1700000000000", unit: .automatic, timeZone: TimeZone(secondsFromGMT: 0)!).contains("2023-11-14 22:13:20"), "Millisecond conversion")
        check(try TextWorkbench.timestamp("0", unit: .seconds, timeZone: TimeZone(secondsFromGMT: 0)!).contains("1970-01-01"), "Epoch conversion")
        do { _ = try TextWorkbench.timestamp("nan", unit: .seconds); fatalError("NaN accepted") } catch {}
        let diff = try TextWorkbench.diff("a\nb\nc", "a\nx\nc")
        check(diff.contains("- b") && diff.contains("+ x") && diff.contains("  c"), "Line replacements")
        check(try TextWorkbench.diff("a", "a") == "  a", "Equal text")
        check(try TextWorkbench.diff("", "new") == "+ new", "Empty source")
        do { _ = try TextWorkbench.diff(String(repeating: "a\n", count: 2001), "b"); fatalError("Unbounded diff accepted") } catch {}
        print("PASS: JSON validation/escaping, timestamp units, detection, line diff and bounded processing")
    }
}
