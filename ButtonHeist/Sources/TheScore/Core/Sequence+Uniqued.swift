package extension Sequence {
    func uniqued<Key: Hashable>(
        on key: (Element) -> Key,
        excluding initialKeys: Set<Key> = []
    ) -> [Element] {
        var seen = initialKeys
        return filter { seen.insert(key($0)).inserted }
    }
}
