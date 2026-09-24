import XCTest
import PythonXPCService

/// `OPENSSL_CONF` must name the `openssl.cnf` next to `site-python`, so no OpenSSL in the process reads a configuration
/// from outside the bundle (`cryptography`'s own copy defaults to `/opt/homebrew/etc/openssl@3`).
final class GaragePythonRuntimeOpenSSLTests: XCTestCase {
    private var root: URL!
    private var savedOpenSSLConf: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GaragePythonRuntimeOpenSSLTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("site-python", isDirectory: true), withIntermediateDirectories: true)
        savedOpenSSLConf = currentOpenSSLConf
    }

    override func tearDownWithError() throws {
        if let savedOpenSSLConf {
            setenv(GaragePythonRuntime.opensslConfEnvironmentKey, savedOpenSSLConf, 1)
        } else {
            unsetenv(GaragePythonRuntime.opensslConfEnvironmentKey)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private var currentOpenSSLConf: String? {
        getenv(GaragePythonRuntime.opensslConfEnvironmentKey).map { String(cString: $0) }
    }

    private var environment: GaragePythonEnvironment {
        GaragePythonEnvironment(sitePythonURL: root.appendingPathComponent("site-python", isDirectory: true))
    }

    private func writeConfig() throws -> URL {
        let url = root.appendingPathComponent("openssl.cnf")
        try Data().write(to: url)
        return url
    }

    func testExportsTheConfigNextToSitePython() throws {
        let config = try writeConfig()

        let exported = GaragePythonRuntime.exportBundledOpenSSLConfig(for: environment)

        XCTAssertEqual(exported, config.path)
        XCTAssertEqual(currentOpenSSLConf, config.path)
    }

    func testReplacesAnInheritedValue() throws {
        let config = try writeConfig()
        setenv("OPENSSL_CONF", "/opt/homebrew/etc/openssl@3/openssl.cnf", 1)

        GaragePythonRuntime.exportBundledOpenSSLConfig(for: environment)

        XCTAssertEqual(currentOpenSSLConf, config.path)
    }

    func testLeavesTheEnvironmentAloneWithoutABundledConfig() {
        setenv("OPENSSL_CONF", "/somewhere/else.cnf", 1)

        XCTAssertNil(GaragePythonRuntime.bundledOpenSSLConfigURL(for: environment))
        XCTAssertNil(GaragePythonRuntime.exportBundledOpenSSLConfig(for: environment))
        XCTAssertEqual(currentOpenSSLConf, "/somewhere/else.cnf")
    }

    func testIgnoresADirectoryNamedLikeTheConfig() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("openssl.cnf", isDirectory: true), withIntermediateDirectories: true)

        XCTAssertNil(GaragePythonRuntime.bundledOpenSSLConfigURL(for: environment))
    }
}
