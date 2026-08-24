public enum BrightnessWriteCommit {
    @MainActor
    public static func perform<Value>(
        write: @MainActor () async throws -> Value,
        commit: @MainActor (Value) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = try await write()
        try Task.checkCancellation()
        commit(value)
        return value
    }
}
