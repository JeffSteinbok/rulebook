import Foundation
import Testing
@testable import RulebookKit
import RulebookTesting

@Suite("GraphMailFolderDirectory")
struct FolderDirectoryTests {

    @Test("Nested and hidden folders are found, and named by their path")
    func walksTheTree() async throws {
        let names = try await FakeGraph().makeFolderDirectory().folders().compactMap(\.name)
        #expect(names.contains("Inbox/Newsletters/Tech"))
        #expect(names.contains("Inbox/Receipts"))
        #expect(names.contains("Sync Issues"), "Rules can target hidden folders.")
        #expect(names == names.sorted())
    }

    @Test("A folder resolves by full path, by leaf, or by a unique tail", arguments: [
        "Inbox/Newsletters/Tech", "Tech", "Newsletters/Tech", "newsletters/tech", "Receipts",
    ])
    func resolvesNames(_ name: String) async throws {
        let fake = FakeGraph()
        let id = try await fake.makeFolderDirectory().id(forName: name)
        #expect(id != nil)
        #expect(id == fake.folderID(named: String(name.split(separator: "/").last!).capitalized)
                    || id == fake.folderID(named: "Tech") || id == fake.folderID(named: "Receipts"))
    }

    @Test("An ambiguous leaf name resolves to nothing rather than a guess")
    func ambiguousLeaf() async throws {
        var folders = FakeGraph.standardFolders
        folders.append(["id": "dup-tech", "displayName": "Tech", "parentFolderId": "fake-archive",
                        "childFolderCount": 0, "isHidden": false])
        folders = folders.map { folder in
            var folder = folder
            if folder["id"] as? String == "fake-archive" { folder["childFolderCount"] = 1 }
            return folder
        }
        let directory = FakeGraph(folders: folders).makeFolderDirectory()
        #expect(try await directory.id(forName: "Tech") == nil)
        #expect(try await directory.id(forName: "Archive/Tech") == "dup-tech")
    }

    @Test("The tree is fetched once and then served from cache")
    func caches() async throws {
        let fake = FakeGraph()
        let directory = fake.makeFolderDirectory()
        _ = try await directory.folders()
        let first = fake.requests.count
        _ = try await directory.name(forID: "fake-tech")
        _ = try await directory.id(forName: "Receipts")
        #expect(fake.requests.count == first)
    }
}
