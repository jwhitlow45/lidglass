/// A release version such as 1.2.3, read from the app or from a release tag like v1.2.3.
///
/// Missing trailing parts count as zero, so 1.2 and 1.2.0 are the same version. Anything
/// that is not plain numbers, such as 1.2.3-beta, is not a version the updater installs.
public struct ReleaseVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let number = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = number.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...4).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let (left, right) = padded(lhs, rhs)
        return left.lexicographicallyPrecedes(right)
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let (left, right) = padded(lhs, rhs)
        return left == right
    }

    private static func padded(_ lhs: ReleaseVersion, _ rhs: ReleaseVersion) -> ([Int], [Int]) {
        let count = max(lhs.parts.count, rhs.parts.count)
        return (lhs.parts + Array(repeating: 0, count: count - lhs.parts.count),
                rhs.parts + Array(repeating: 0, count: count - rhs.parts.count))
    }
}
