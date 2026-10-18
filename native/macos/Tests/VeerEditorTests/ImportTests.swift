import Foundation
import Testing
@testable import VeerEditor

@Test func importRejectsOversizeEmptyAndInvalidEncoding() throws {
    #expect(throws: EditorFailure.self) { try ConfigurationImport.decode(Data()) }
    #expect(throws: EditorFailure.self) { try ConfigurationImport.decode(Data([0xff])) }
    #expect(throws: EditorFailure.self) { try ConfigurationImport.decode(Data(repeating: 65, count: ConfigurationImport.maximumBytes + 1)) }
    #expect(try ConfigurationImport.decode(Data("rules: []\n".utf8)) == "rules: []\n")
}

@Test func subscriptionRequiresHTTPSAndHidesURLInErrors() throws {
    for input in ["http://example.com/?token=test-secret", "https://user:password@example.com", "file:///tmp/test", "not a URL"] {
        do { _ = try ConfigurationImport.subscriptionURL(input); Issue.record("Should reject") }
        catch { #expect(!error.localizedDescription.contains("test-secret")); #expect(!error.localizedDescription.contains("password")) }
    }
    #expect(try ConfigurationImport.subscriptionURL("https://example.com/config?token=fixture").scheme == "https")
}

@Test func exportRejectsOriginalPathSymlinkAndHardlink() throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.yaml")
    try "rules: []\n".write(to: source, atomically: true, encoding: .utf8)
    let symbolic = folder.appendingPathComponent("symbolic.yaml")
    let hardlink = folder.appendingPathComponent("hardlink.yaml")
    try fm.createSymbolicLink(at: symbolic, withDestinationURL: source)
    try fm.linkItem(at: source, to: hardlink)
    for target in [source, symbolic, hardlink] {
        #expect(throws: EditorFailure.self) { try ConfigurationImport.verifyExportDestination(target, importedFile: source) }
    }
    try ConfigurationImport.verifyExportDestination(folder.appendingPathComponent("copy.yaml"), importedFile: source)
    #expect(try String(contentsOf: source, encoding: .utf8) == "rules: []\n")
}

@Test func importedSessionStartsCleanAndUndoDoesNotCrossDocumentBoundary() {
    var session = DraftSession()
    session.editRules("rules: [DOMAIN-SUFFIX,old.example,DIRECT]")
    let imported = Draft(groups: [.init(name: "日本出口", region: "JP")], rules: "rules: [MATCH,DIRECT]\n")
    session.loadDocument(imported)
    #expect(!session.canUndo)
    #expect(!session.hasUnsavedChanges)
    session.editRules("rules: [DOMAIN-SUFFIX,new.example,DIRECT, MATCH,DIRECT]\n")
    #expect(session.hasUnsavedChanges)
    let undone = session.undo()
    #expect(undone)
    #expect(session.draft == imported)
    #expect(!session.hasUnsavedChanges)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) func fullDocumentClientRoundTrip() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["VEER_TEST_PORT"])
    let client = try EditorClient(port: #require(Int(raw)))
    let source = "# retained header\nmode: rule\ndns: {enable: false}\nrules:\n  - MATCH,DIRECT\n"
    let draft = try await client.importDocument(source)
    #expect(draft.groups.isEmpty)
    let preview = try await client.generate(draft, prompt: "example.com 直连", mode: "local", settings: AISettings(), source: source)
    #expect(preview.changed)
    #expect(preview.validation.status != "failed")
    #expect(preview.candidate.contains("MATCH,DIRECT"))
    let exported = try await client.exportDocument(source, draft: Draft(groups: draft.groups, rules: preview.candidate))
    #expect(exported.hasPrefix("# retained header\nmode: rule\ndns: {enable: false}\n"))
    #expect(exported.contains("DOMAIN-SUFFIX,example.com,DIRECT"))
    #expect(try await client.exportDocument(source, draft: draft) == source)
}
