import BumperBowlingCore
import SwiftSyntax

/// Distinguish contracts from accessor-local scratch without hiding fields of local types.
func isContractDeclaration(_ node: some SyntaxProtocol) -> Bool {
    // shortcut: Bumper 0.7.1 misses getter scopes; remove after adopting the upstream accessor fix.
    for ancestor in node.ancestors {
        if ancestor.is(AccessorBlockSyntax.self) { return false }
        if ancestor.is(MemberBlockItemSyntax.self) { break }
    }
    return node.lexicalPlacement != .local
}
