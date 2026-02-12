import XCTest
@testable import Geistty

// MARK: - ConnectionProfile Tests

final class ConnectionProfileTests: XCTestCase {

    // MARK: - displayString

    func testDisplayStringDefaultPort() {
        let profile = ConnectionProfile(
            name: "Test Server",
            host: "example.com",
            port: 22,
            username: "admin"
        )
        XCTAssertEqual(profile.displayString, "admin@example.com")
    }

    func testDisplayStringCustomPort() {
        let profile = ConnectionProfile(
            name: "Test Server",
            host: "example.com",
            port: 2222,
            username: "admin"
        )
        XCTAssertEqual(profile.displayString, "admin@example.com:2222")
    }

    func testDisplayStringPort22Explicit() {
        let profile = ConnectionProfile(
            name: "Dev",
            host: "192.168.1.100",
            port: 22,
            username: "root"
        )
        XCTAssertEqual(profile.displayString, "root@192.168.1.100")
    }

    // MARK: - AuthMethod

    func testAuthMethodRawValues() {
        XCTAssertEqual(AuthMethod.sshKey.rawValue, "ssh_key")
        XCTAssertEqual(AuthMethod.password.rawValue, "password")
    }

    func testAuthMethodDisplayName() {
        XCTAssertEqual(AuthMethod.sshKey.displayName, "SSH Key")
        XCTAssertEqual(AuthMethod.password.displayName, "Password")
    }

    func testAuthMethodIcon() {
        XCTAssertEqual(AuthMethod.sshKey.icon, "key.horizontal.fill")
        XCTAssertEqual(AuthMethod.password.icon, "textformat.abc")
    }

    func testAuthMethodDescription() {
        XCTAssertFalse(AuthMethod.sshKey.description.isEmpty)
        XCTAssertFalse(AuthMethod.password.description.isEmpty)
    }

    func testAuthMethodId() {
        XCTAssertEqual(AuthMethod.sshKey.id, "ssh_key")
        XCTAssertEqual(AuthMethod.password.id, "password")
    }

    func testAuthMethodAllCases() {
        XCTAssertEqual(AuthMethod.allCases.count, 2)
        XCTAssertTrue(AuthMethod.allCases.contains(.sshKey))
        XCTAssertTrue(AuthMethod.allCases.contains(.password))
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let original = ConnectionProfile(
            name: "Production",
            host: "prod.example.com",
            port: 2222,
            username: "deploy",
            authMethod: .sshKey,
            sshKeyName: "deploy_key",
            useTmux: true,
            tmuxSessionName: "deploy-session",
            enableFilesIntegration: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "Production")
        XCTAssertEqual(decoded.host, "prod.example.com")
        XCTAssertEqual(decoded.port, 2222)
        XCTAssertEqual(decoded.username, "deploy")
        XCTAssertEqual(decoded.authMethod, .sshKey)
        XCTAssertEqual(decoded.sshKeyName, "deploy_key")
        XCTAssertEqual(decoded.useTmux, true)
        XCTAssertEqual(decoded.tmuxSessionName, "deploy-session")
        XCTAssertEqual(decoded.enableFilesIntegration, true)
        XCTAssertEqual(decoded.isFavorite, false)
        XCTAssertNil(decoded.lastConnectedAt)
        XCTAssertNil(decoded.colorTag)
    }

    func testCodableRoundTripPassword() throws {
        let original = ConnectionProfile(
            name: "Dev Box",
            host: "10.0.0.5",
            port: 22,
            username: "dev",
            authMethod: .password
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(decoded.authMethod, .password)
        XCTAssertNil(decoded.sshKeyName)
        XCTAssertEqual(decoded.useTmux, false)
        XCTAssertNil(decoded.tmuxSessionName)
        XCTAssertEqual(decoded.enableFilesIntegration, false)
    }

    // MARK: - Migration: Missing Fields Default Correctly

    func testMigrationMissingTmuxFields() throws {
        // Simulate old profile JSON without useTmux/tmuxSessionName/enableFilesIntegration
        let oldJSON: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Old Server",
            "host": "old.example.com",
            "port": 22,
            "username": "user",
            "authMethod": "ssh_key",
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "isFavorite": false
        ]

        let data = try JSONSerialization.data(withJSONObject: oldJSON)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        // These should default to false/nil when missing from JSON
        XCTAssertEqual(decoded.useTmux, false)
        XCTAssertNil(decoded.tmuxSessionName)
        XCTAssertEqual(decoded.enableFilesIntegration, false)
        XCTAssertEqual(decoded.name, "Old Server")
        XCTAssertEqual(decoded.host, "old.example.com")
    }

    // MARK: - Initialization Defaults

    func testDefaultValues() {
        let profile = ConnectionProfile(
            name: "Test",
            host: "host.com",
            username: "user"
        )

        XCTAssertEqual(profile.port, 22)
        XCTAssertEqual(profile.authMethod, .sshKey)
        XCTAssertNil(profile.sshKeyName)
        XCTAssertEqual(profile.useTmux, false)
        XCTAssertNil(profile.tmuxSessionName)
        XCTAssertEqual(profile.enableFilesIntegration, false)
        XCTAssertEqual(profile.isFavorite, false)
        XCTAssertNil(profile.lastConnectedAt)
        XCTAssertNil(profile.colorTag)
    }

    // MARK: - Hashable

    func testHashable() {
        let profile1 = ConnectionProfile(
            name: "Server A",
            host: "a.com",
            username: "user"
        )
        let profile2 = ConnectionProfile(
            name: "Server B",
            host: "b.com",
            username: "user"
        )

        var set = Set<ConnectionProfile>()
        set.insert(profile1)
        set.insert(profile2)
        XCTAssertEqual(set.count, 2)

        // Same profile inserted again
        set.insert(profile1)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - authIcon

    func testAuthIcon() {
        let keyProfile = ConnectionProfile(
            name: "Key Auth",
            host: "host.com",
            username: "user",
            authMethod: .sshKey
        )
        XCTAssertEqual(keyProfile.authIcon, "key.horizontal.fill")

        let passProfile = ConnectionProfile(
            name: "Pass Auth",
            host: "host.com",
            username: "user",
            authMethod: .password
        )
        XCTAssertEqual(passProfile.authIcon, "textformat.abc")
    }

    // MARK: - Identifiable

    func testIdentifiable() {
        let profile = ConnectionProfile(
            name: "Test",
            host: "host.com",
            username: "user"
        )
        XCTAssertEqual(profile.id, profile.id) // UUID is stable
        XCTAssertFalse(profile.id.uuidString.isEmpty)
    }

    // MARK: - Edge Cases

    func testEmptyStrings() {
        let profile = ConnectionProfile(
            name: "",
            host: "",
            username: ""
        )
        XCTAssertEqual(profile.displayString, "@")
    }

    func testSpecialCharactersInHostname() {
        let profile = ConnectionProfile(
            name: "Tailscale",
            host: "my-server.tail12345.ts.net",
            port: 22,
            username: "user"
        )
        XCTAssertEqual(profile.displayString, "user@my-server.tail12345.ts.net")
    }

    func testIPv6Host() {
        let profile = ConnectionProfile(
            name: "IPv6",
            host: "::1",
            port: 22,
            username: "root"
        )
        XCTAssertEqual(profile.displayString, "root@::1")
    }
}
