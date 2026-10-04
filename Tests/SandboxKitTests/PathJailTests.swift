import Foundation
import XCTest
@testable import SandboxKit

final class PathJailTests: XCTestCase {
    var base: URL!
    var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("jail-\(UUID().uuidString)")
        root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("outside"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func testInsidePathsResolve() throws {
        let jail = try PathJail(root: root.path)
        XCTAssertEqual(jail.relative(try jail.resolve("src")), "src")
        XCTAssertEqual(jail.relative(try jail.resolve("src/../src/new/file.txt")), "src/new/file.txt")
        XCTAssertEqual(jail.relative(try jail.resolve(".")), ".")
        XCTAssertEqual(jail.relative(try jail.resolve(jail.root.path + "/src")), "src")
    }

    func testDotDotEscapeIsRefused() throws {
        let jail = try PathJail(root: root.path)
        XCTAssertThrowsError(try jail.resolve("../outside"))
        XCTAssertThrowsError(try jail.resolve("src/../../outside/x"))
        XCTAssertThrowsError(try jail.resolve("/etc/passwd"))
    }

    func testSiblingWithSharedPrefixIsRefused() throws {
        try FileManager.default.createDirectory(at: base.appendingPathComponent("project-evil"), withIntermediateDirectories: true)
        let jail = try PathJail(root: root.path)
        XCTAssertThrowsError(try jail.resolve(base.appendingPathComponent("project-evil/x").path))
    }

    func testSymlinkOutIsRefused() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: base.appendingPathComponent("outside"))
        let jail = try PathJail(root: root.path)
        XCTAssertThrowsError(try jail.resolve("link"))
        XCTAssertThrowsError(try jail.resolve("link/new.txt"))
    }

    func testDanglingSymlinkIsRefused() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"),
                                                   withDestinationURL: base.appendingPathComponent("outside/missing"))
        let jail = try PathJail(root: root.path)
        XCTAssertThrowsError(try jail.resolve("dangling"))
    }

    func testSymlinkWithinIsAllowed() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                   withDestinationURL: root.appendingPathComponent("src"))
        let jail = try PathJail(root: root.path)
        XCTAssertEqual(jail.relative(try jail.resolve("alias/a.txt")), "src/a.txt")
    }
}
