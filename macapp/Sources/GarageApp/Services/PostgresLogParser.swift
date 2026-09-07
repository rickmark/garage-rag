import Foundation

/// Parses raw stderr and stdout lines emitted by PostgreSQL server and tools
/// into structured `LogLine` objects with parsed timestamp, PID, log level, and message.
public enum PostgresLogParser: Sendable {

    /// Pre-compiled regex patterns for matching various PostgreSQL log line prefix formats.
    /// Standard format with log_line_prefix '%m [%p] ':
    /// `2026-09-07 16:24:13.456 UTC [12345] LOG:  database system is ready`
    private static let standardPrefixRegex: NSRegularExpression? = {
        let pattern = #"^(\d{4}-\d{2}-\d{2}[\sT]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:\s+[A-Z]{2,5}|\s*[\+\-]\d{2}(?::?\d{2})?|Z)?)\s+(?:\[(\d+)\]|pid=(\d+))(?::)?\s*(?:\[\d+-\d+\]\s*)?(?:[^\s:]+@[^\s:]+\s+)?(?:(LOG|INFO|NOTICE|WARNING|WARN|ERROR|FATAL|PANIC|DEBUG[1-5]?|DETAIL|HINT|STATEMENT|CONTEXT|LOCATION|QUERY):(?:\s{1,2}(.*)|$)|(.*))$"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Fallback regex for lines starting with timestamp and level (without PID):
    /// `2026-09-07 16:24:13.456 UTC LOG:  database system is ready`
    private static let timestampLevelRegex: NSRegularExpression? = {
        let pattern = #"^(\d{4}-\d{2}-\d{2}[\sT]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:\s+[A-Z]{2,5}|\s*[\+\-]\d{2}(?::?\d{2})?|Z)?)\s+(LOG|INFO|NOTICE|WARNING|WARN|ERROR|FATAL|PANIC|DEBUG[1-5]?|DETAIL|HINT|STATEMENT|CONTEXT|LOCATION|QUERY):(?:\s{1,2}(.*)|$)"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Fallback regex for lines with PID and level (without timestamp):
    /// `[12345] LOG:  database system is ready` or `[12345]: LOG:  ...`
    private static let pidLevelRegex: NSRegularExpression? = {
        let pattern = #"^(?:\[(\d+)\]|pid=(\d+))(?::)?\s*(?:\[\d+-\d+\]\s*)?(?:[^\s:]+@[^\s:]+\s+)?(?:(LOG|INFO|NOTICE|WARNING|WARN|ERROR|FATAL|PANIC|DEBUG[1-5]?|DETAIL|HINT|STATEMENT|CONTEXT|LOCATION|QUERY):(?:\s{1,2}(.*)|$)|(.*))$"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Fallback regex for lines with level prefix only:
    /// `LOG:  database system is ready`
    private static let levelOnlyRegex: NSRegularExpression? = {
        let pattern = #"^(LOG|INFO|NOTICE|WARNING|WARN|ERROR|FATAL|PANIC|DEBUG[1-5]?|DETAIL|HINT|STATEMENT|CONTEXT|LOCATION|QUERY):(?:\s{1,2}(.*)|$)"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Date formatters for parsing timestamps emitted by PostgreSQL (%m, %t, ISO8601).
    private static let dateParserHelpers: [(regex: NSRegularExpression, formatter: DateFormatter)] = {
        let formats: [(pattern: String, format: String)] = [
            (#"^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{3}\s[A-Z]{2,5}$"#, "yyyy-MM-dd HH:mm:ss.SSS zzz"),
            (#"^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{3}\s*[\+\-]\d{2}:?\d{2}$"#, "yyyy-MM-dd HH:mm:ss.SSS Z"),
            (#"^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{3}$"#, "yyyy-MM-dd HH:mm:ss.SSS"),
            (#"^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\s[A-Z]{2,5}$"#, "yyyy-MM-dd HH:mm:ss zzz"),
            (#"^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\s*[\+\-]\d{2}:?\d{2}$"#, "yyyy-MM-dd HH:mm:ss Z"),
            (#"^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}$"#, "yyyy-MM-dd HH:mm:ss"),
            (#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}.*$"#, "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"),
            (#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*$"#, "yyyy-MM-dd'T'HH:mm:ssZZZZZ")
        ]

        return formats.compactMap { item in
            guard let regex = try? NSRegularExpression(pattern: item.pattern, options: []) else { return nil }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = item.format
            return (regex, df)
        }
    }()

    /// Parses a date string from PostgreSQL logs into a `Date`.
    public static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Normalize microsecond precision (e.g. .123456) to milliseconds (.123)
        var normalized = trimmed
        if let dotRange = normalized.range(of: #"\.\d{4,6}"#, options: .regularExpression) {
            let start = dotRange.lowerBound
            let afterDot = normalized.index(after: start)
            let milliEnd = normalized.index(afterDot, offsetBy: 3)
            let replacement = String(normalized[start..<milliEnd])
            normalized.replaceSubrange(dotRange, with: replacement)
        }

        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        for helper in dateParserHelpers {
            if helper.regex.firstMatch(in: normalized, options: [], range: fullRange) != nil {
                if let parsed = helper.formatter.date(from: normalized) {
                    return parsed
                }
            }
        }

        // Fallback to ISO8601 parser
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = iso.date(from: normalized) {
            return parsed
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: normalized)
    }

    /// Maps PostgreSQL severity string (e.g. "LOG", "ERROR", "PANIC") to `LogLevel`.
    public static func parseLogLevel(_ string: String) -> LogLevel {
        let upper = string.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch upper {
        case "PANIC", "FATAL", "ERROR":
            return .error
        case "WARNING", "WARN":
            return .warning
        case "DEBUG", "DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5":
            return .debug
        case "LOG", "INFO", "NOTICE", "DETAIL", "HINT", "STATEMENT", "CONTEXT", "LOCATION", "QUERY":
            return .info
        default:
            return .info
        }
    }

    /// Parses a Postgres process ID string (e.g. "12345") into `Int32?`.
    public static func parsePID(_ string: String) -> Int32? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(trimmed)
    }

    /// Parses a raw PostgreSQL output line into a fully populated `LogLine`.
    public static func parse(
        rawText: String,
        fallbackDate: Date = Date(),
        stream: LogLine.Stream = .stderr,
        source: String = "postgres"
    ) -> LogLine {
        let fullRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)

        // 1. Try standard prefix: timestamp + PID + (optional level) + message
        if let regex = standardPrefixRegex,
           let match = regex.firstMatch(in: rawText, options: [], range: fullRange) {
            var parsedDate: Date?
            var parsedPID: Int32?
            var parsedLevel: LogLevel?
            var message = rawText

            // Timestamp (Group 1)
            if let dateRange = Range(match.range(at: 1), in: rawText) {
                parsedDate = parseDate(String(rawText[dateRange]))
            }

            // PID (Group 2 or Group 3)
            if match.range(at: 2).location != NSNotFound,
               let pidRange = Range(match.range(at: 2), in: rawText) {
                parsedPID = parsePID(String(rawText[pidRange]))
            } else if match.range(at: 3).location != NSNotFound,
                      let pidRange = Range(match.range(at: 3), in: rawText) {
                parsedPID = parsePID(String(rawText[pidRange]))
            }

            // Level (Group 4)
            if match.range(at: 4).location != NSNotFound,
               let levelRange = Range(match.range(at: 4), in: rawText) {
                let levelStr = String(rawText[levelRange])
                parsedLevel = parseLogLevel(levelStr)

                // Message after level (Group 5)
                if match.range(at: 5).location != NSNotFound,
                   let msgRange = Range(match.range(at: 5), in: rawText) {
                    let msg = String(rawText[msgRange])
                    // For contextual tags (DETAIL, HINT, STATEMENT, etc.), retain the tag in the text
                    if ["DETAIL", "HINT", "STATEMENT", "CONTEXT", "LOCATION", "QUERY"].contains(levelStr.uppercased()) {
                        message = "\(levelStr): \(msg)"
                    } else {
                        message = msg
                    }
                } else {
                    message = ""
                }
            } else if match.range(at: 6).location != NSNotFound,
                      let msgRange = Range(match.range(at: 6), in: rawText) {
                message = String(rawText[msgRange])
            }

            let effectiveLevel = parsedLevel ?? (stream == .stderr ? LogLine.inferLevel(stream: stream, text: message) : .info)

            return LogLine(
                date: parsedDate ?? fallbackDate,
                stream: stream,
                text: message,
                source: source,
                level: effectiveLevel,
                pid: parsedPID,
                rawText: rawText
            )
        }

        // 2. Try timestamp + level (no PID)
        if let regex = timestampLevelRegex,
           let match = regex.firstMatch(in: rawText, options: [], range: fullRange) {
            var parsedDate: Date?
            var parsedLevel: LogLevel?
            var message = rawText

            if let dateRange = Range(match.range(at: 1), in: rawText) {
                parsedDate = parseDate(String(rawText[dateRange]))
            }

            if let levelRange = Range(match.range(at: 2), in: rawText) {
                let levelStr = String(rawText[levelRange])
                parsedLevel = parseLogLevel(levelStr)

                if match.range(at: 3).location != NSNotFound,
                   let msgRange = Range(match.range(at: 3), in: rawText) {
                    let msg = String(rawText[msgRange])
                    if ["DETAIL", "HINT", "STATEMENT", "CONTEXT", "LOCATION", "QUERY"].contains(levelStr.uppercased()) {
                        message = "\(levelStr): \(msg)"
                    } else {
                        message = msg
                    }
                } else {
                    message = ""
                }
            }

            return LogLine(
                date: parsedDate ?? fallbackDate,
                stream: stream,
                text: message,
                source: source,
                level: parsedLevel,
                pid: nil,
                rawText: rawText
            )
        }

        // 3. Try PID + level (no timestamp)
        if let regex = pidLevelRegex,
           let match = regex.firstMatch(in: rawText, options: [], range: fullRange) {
            var parsedPID: Int32?
            var parsedLevel: LogLevel?
            var message = rawText

            if match.range(at: 1).location != NSNotFound,
               let pidRange = Range(match.range(at: 1), in: rawText) {
                parsedPID = parsePID(String(rawText[pidRange]))
            } else if match.range(at: 2).location != NSNotFound,
                      let pidRange = Range(match.range(at: 2), in: rawText) {
                parsedPID = parsePID(String(rawText[pidRange]))
            }

            if match.range(at: 3).location != NSNotFound,
               let levelRange = Range(match.range(at: 3), in: rawText) {
                let levelStr = String(rawText[levelRange])
                parsedLevel = parseLogLevel(levelStr)

                if match.range(at: 4).location != NSNotFound,
                   let msgRange = Range(match.range(at: 4), in: rawText) {
                    let msg = String(rawText[msgRange])
                    if ["DETAIL", "HINT", "STATEMENT", "CONTEXT", "LOCATION", "QUERY"].contains(levelStr.uppercased()) {
                        message = "\(levelStr): \(msg)"
                    } else {
                        message = msg
                    }
                } else {
                    message = ""
                }
            } else if match.range(at: 5).location != NSNotFound,
                      let msgRange = Range(match.range(at: 5), in: rawText) {
                message = String(rawText[msgRange])
            }

            let effectiveLevel = parsedLevel ?? (stream == .stderr ? LogLine.inferLevel(stream: stream, text: message) : .info)

            return LogLine(
                date: fallbackDate,
                stream: stream,
                text: message,
                source: source,
                level: effectiveLevel,
                pid: parsedPID,
                rawText: rawText
            )
        }

        // 4. Try level only (e.g. "LOG:  database system was shut down")
        if let regex = levelOnlyRegex,
           let match = regex.firstMatch(in: rawText, options: [], range: fullRange) {
            if let levelRange = Range(match.range(at: 1), in: rawText) {
                let levelStr = String(rawText[levelRange])
                let parsedLevel = parseLogLevel(levelStr)
                var message = ""

                if match.range(at: 2).location != NSNotFound,
                   let msgRange = Range(match.range(at: 2), in: rawText) {
                    let msg = String(rawText[msgRange])
                    if ["DETAIL", "HINT", "STATEMENT", "CONTEXT", "LOCATION", "QUERY"].contains(levelStr.uppercased()) {
                        message = "\(levelStr): \(msg)"
                    } else {
                        message = msg
                    }
                }

                return LogLine(
                    date: fallbackDate,
                    stream: stream,
                    text: message,
                    source: source,
                    level: parsedLevel,
                    pid: nil,
                    rawText: rawText
                )
            }
        }

        // 5. Default fallback for unformatted / generic lines
        let inferred = LogLine.inferLevel(stream: stream, text: rawText)
        return LogLine(
            date: fallbackDate,
            stream: stream,
            text: rawText,
            source: source,
            level: inferred,
            pid: nil,
            rawText: rawText
        )
    }

    /// Convenience overload to parse an already created `LogLine`.
    public static func parse(line: LogLine) -> LogLine {
        parse(
            rawText: line.rawText ?? line.text,
            fallbackDate: line.date,
            stream: line.stream,
            source: line.source
        )
    }
}
