import Testing
@testable import SecondMindKit

@Suite struct MiniTOMLTests {
    @Test func scalarWithInlineComment() {
        // THE v1 bug class: comment after a quoted value must be discarded.
        let t = MiniTOML(string: #"""
        [models]
        opus = "claude-opus-4-8"   # opus-latest also acceptable. No exceptions.
        """#)
        #expect(t.string("models.opus") == "claude-opus-4-8")
    }

    @Test func literalStringKeepsBackslashes() {
        let t = MiniTOML(string: #"""
        [sensors.filesystem]
        exclude_regex = '/\.git/|/node_modules/'
        """#)
        #expect(t.string("sensors.filesystem.exclude_regex") == #"/\.git/|/node_modules/"#)
    }

    @Test func bareValuesAndTypes() {
        let t = MiniTOML(string: """
        [server]
        port = 4517
        enabled = true   # comment on bare value
        ratio = 0.5
        """)
        #expect(t.int("server.port") == 4517)
        #expect(t.bool("server.enabled") == true)
        #expect(t.double("server.ratio") == 0.5)
    }

    @Test func singleLineArray() {
        let t = MiniTOML(string: """
        [privacy]
        apps = ["com.1password.1password", "com.bitwarden.desktop"]
        """)
        #expect(t.array("privacy.apps") == ["com.1password.1password", "com.bitwarden.desktop"])
    }

    @Test func multiLineArray() {
        let t = MiniTOML(string: """
        [privacy]
        paths = [
            "~/.ssh",
            "~/.aws",
        ]
        """)
        #expect(t.array("privacy.paths") == ["~/.ssh", "~/.aws"])
        #expect(t.paths("privacy.paths")?.allSatisfy { $0.hasPrefix("/") } == true)
    }

    @Test func hashInsideQuotedArrayItemSurvives() {
        let t = MiniTOML(string: """
        [x]
        items = ["a#b", "c"]
        """)
        #expect(t.array("x.items") == ["a#b", "c"])
    }

    @Test func tildeExpansion() {
        let t = MiniTOML(string: """
        [paths]
        vault = "~/Projects/2ndm1nd"
        """)
        #expect(t.path("paths.vault")?.hasSuffix("/Projects/2ndm1nd") == true)
        #expect(t.path("paths.vault")?.hasPrefix("/") == true)
    }
}
