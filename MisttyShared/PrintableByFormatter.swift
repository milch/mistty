public protocol PrintableByFormatter {
    static func formatHeader() -> [String]
    func formatRow() -> [String]
}
