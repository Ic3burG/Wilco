import Testing
@testable import WilcoCore

@Suite("Term list editing")
struct TermListTests {
    @Test func addsOneTerm() {
        #expect(TermList.adding("Pyro", to: []) == ["Pyro"])
    }

    @Test func splitsPastedLinesAndCommas() {
        let pasted = "Fly 12\nLX Q 40, Sound Q 3\r\n  Deck Left  "
        #expect(TermList.adding(pasted, to: ["Pyro"]) == ["Pyro", "Fly 12", "LX Q 40", "Sound Q 3", "Deck Left"])
    }

    @Test func dropsBlanksAndCaseInsensitiveDuplicates() {
        let pasted = "pyro,, \n Fly 12\nFLY 12\n"
        #expect(TermList.adding(pasted, to: ["Pyro"]) == ["Pyro", "Fly 12"])
    }

    @Test func blankInputLeavesListUnchanged() {
        #expect(TermList.adding("  \n , ", to: ["Pyro"]) == ["Pyro"])
    }

    @Test func filtersCaseInsensitively() {
        let terms = ["Pyro", "Fly 12", "pyrotechnics"]
        #expect(TermList.filter(terms, matching: "PYR") == ["Pyro", "pyrotechnics"])
        #expect(TermList.filter(terms, matching: "  ") == terms)
    }

    @Test func sortsAlphabeticallyIgnoringCase() {
        #expect(TermList.sorted(["deck", "Act 2", "Fly", "act 1"]) == ["act 1", "Act 2", "deck", "Fly"])
    }
}
