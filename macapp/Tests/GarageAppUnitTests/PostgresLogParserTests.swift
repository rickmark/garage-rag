import XCTest
@testable import GarageApp

final class PostgresLogParserTests: XCTestCase {

    func testStandardLogLineWithTimestampPidAndLevel() {
        let raw = "2026-09-07 16:24:13.456 UTC [12345] LOG:  database system is ready to accept connections"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 12345)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.text, "database system is ready to accept connections")
        XCTAssertEqual(line.rawText, raw)
        XCTAssertEqual(line.stream, .stderr)
        XCTAssertEqual(line.source, "postgres")

        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: line.date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 7)
        XCTAssertEqual(components.hour, 16)
        XCTAssertEqual(components.minute, 24)
        XCTAssertEqual(components.second, 13)
    }

    func testErrorLogLine() {
        let raw = "2026-09-07 16:24:13.456 EDT [9876] ERROR:  relation \"nonexistent_table\" does not exist"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 9876)
        XCTAssertEqual(line.level, .error)
        XCTAssertEqual(line.text, "relation \"nonexistent_table\" does not exist")
    }

    func testWarningLogLine() {
        let raw = "2026-09-07 16:24:13.456 [4567] WARNING:  there is already a transaction in progress"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 4567)
        XCTAssertEqual(line.level, .warning)
        XCTAssertEqual(line.text, "there is already a transaction in progress")
    }

    func testFatalLogLine() {
        let raw = "2026-09-07 16:24:13.456 UTC [1111] FATAL:  the database system is shutting down"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 1111)
        XCTAssertEqual(line.level, .error)
        XCTAssertEqual(line.text, "the database system is shutting down")
    }

    func testPanicLogLine() {
        let raw = "2026-09-07 16:24:13.456 UTC [2222] PANIC:  could not locate a valid checkpoint record"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 2222)
        XCTAssertEqual(line.level, .error)
        XCTAssertEqual(line.text, "could not locate a valid checkpoint record")
    }

    func testDebugLogLine() {
        let raw = "2026-09-07 16:24:13.456 UTC [3333] DEBUG1:  running sequential scan on pg_class"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 3333)
        XCTAssertEqual(line.level, .debug)
        XCTAssertEqual(line.text, "running sequential scan on pg_class")
    }

    func testNoticeAndInfoLogLines() {
        let noticeRaw = "2026-09-07 16:24:13.456 UTC [4444] NOTICE:  table \"test\" does not exist, skipping"
        let noticeLine = PostgresLogParser.parse(rawText: noticeRaw, stream: .stderr, source: "postgres")
        XCTAssertEqual(noticeLine.pid, 4444)
        XCTAssertEqual(noticeLine.level, .info)
        XCTAssertEqual(noticeLine.text, "table \"test\" does not exist, skipping")

        let infoRaw = "2026-09-07 16:24:13.456 UTC [5555] INFO:  checkpoint starting: time"
        let infoLine = PostgresLogParser.parse(rawText: infoRaw, stream: .stderr, source: "postgres")
        XCTAssertEqual(infoLine.pid, 5555)
        XCTAssertEqual(infoLine.level, .info)
        XCTAssertEqual(infoLine.text, "checkpoint starting: time")
    }

    func testDetailHintAndStatementTags() {
        let detailRaw = "2026-09-07 16:24:13.456 UTC [12345] DETAIL:  Key (id)=(1) already exists."
        let detailLine = PostgresLogParser.parse(rawText: detailRaw, stream: .stderr, source: "postgres")
        XCTAssertEqual(detailLine.pid, 12345)
        XCTAssertEqual(detailLine.level, .info)
        XCTAssertEqual(detailLine.text, "DETAIL: Key (id)=(1) already exists.")

        let hintRaw = "2026-09-07 16:24:13.456 UTC [12345] HINT:  Use DROP TABLE ... CASCADE to drop the dependent objects too."
        let hintLine = PostgresLogParser.parse(rawText: hintRaw, stream: .stderr, source: "postgres")
        XCTAssertEqual(hintLine.pid, 12345)
        XCTAssertEqual(hintLine.level, .info)
        XCTAssertEqual(hintLine.text, "HINT: Use DROP TABLE ... CASCADE to drop the dependent objects too.")

        let stmtRaw = "2026-09-07 16:24:13.456 UTC [12345] STATEMENT:  SELECT * FROM test;"
        let stmtLine = PostgresLogParser.parse(rawText: stmtRaw, stream: .stderr, source: "postgres")
        XCTAssertEqual(stmtLine.pid, 12345)
        XCTAssertEqual(stmtLine.level, .info)
        XCTAssertEqual(stmtLine.text, "STATEMENT: SELECT * FROM test;")
    }

    func testSessionAndUserContextPrefixes() {
        let raw = "2026-09-07 16:24:13.456 UTC [12345] [1-1] rickmark@garage-rag LOG:  statement: SELECT 1;"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 12345)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.text, "statement: SELECT 1;")
    }

    func testUnprefixedLogLine() {
        let raw = "LOG:  database system was shut down at 2026-09-07 16:00:00 UTC"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertNil(line.pid)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.text, "database system was shut down at 2026-09-07 16:00:00 UTC")
    }

    func testPidOnlyLogLine() {
        let raw = "[12345] LOG:  database system is ready"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertEqual(line.pid, 12345)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.text, "database system is ready")
    }

    func testTimestampOnlyLogLine() {
        let raw = "2026-09-07 16:24:13.456 UTC LOG:  database system is ready"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertNil(line.pid)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.text, "database system is ready")
    }

    func testPlainStderrFallback() {
        let raw = "postgres: could not access directory \"/var/lib/postgresql\": No such file or directory"
        let line = PostgresLogParser.parse(rawText: raw, stream: .stderr, source: "postgres")

        XCTAssertNil(line.pid)
        XCTAssertEqual(line.level, .error)
        XCTAssertEqual(line.text, raw)
    }

    func testParseExistingLogLineObject() {
        let original = LogLine(
            stream: .stderr,
            text: "2026-09-07 16:24:13.456 UTC [7777] LOG:  checkpoint complete",
            source: "postgres"
        )
        let parsed = PostgresLogParser.parse(line: original)

        XCTAssertEqual(parsed.pid, 7777)
        XCTAssertEqual(parsed.level, .info)
        XCTAssertEqual(parsed.text, "checkpoint complete")
        XCTAssertEqual(parsed.rawText, original.text)
    }

    func testDateParsingVariousFormats() {
        let d1 = PostgresLogParser.parseDate("2026-09-07 16:24:13.456 UTC")
        XCTAssertNotNil(d1)

        let d2 = PostgresLogParser.parseDate("2026-09-07 16:24:13 UTC")
        XCTAssertNotNil(d2)

        let d3 = PostgresLogParser.parseDate("2026-09-07 16:24:13.456")
        XCTAssertNotNil(d3)

        let d4 = PostgresLogParser.parseDate("2026-09-07 16:24:13")
        XCTAssertNotNil(d4)

        let d5 = PostgresLogParser.parseDate("2026-09-07 16:24:13.123456 UTC")
        XCTAssertNotNil(d5)

        let d6 = PostgresLogParser.parseDate("2026-09-07T16:24:13.456Z")
        XCTAssertNotNil(d6)
    }

    func testLogLineSearchMatchesPID() {
        let line = LogLine(
            stream: .stderr,
            text: "checkpoint complete",
            source: "postgres",
            level: .info,
            pid: 54321
        )

        XCTAssertTrue(line.matches(searchText: "54321"))
        XCTAssertTrue(line.matches(searchText: "checkpoint"))
        XCTAssertFalse(line.matches(searchText: "99999"))
    }
}
