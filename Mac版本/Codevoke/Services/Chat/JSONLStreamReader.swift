import Foundation

enum JSONLStreamReader {
    private static let newline: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    // Backstop against a wedged/garbage stream with no newlines accumulating without bound.
    private static let maxLineBytes = 16 * 1024 * 1024

    static func lines(from pipe: Pipe) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = pipe.fileHandleForReading
            let task = Task.detached(priority: .utility) {
                var buffer = Data()
                buffer.reserveCapacity(8 * 1024)
                while !Task.isCancelled {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    appendChunk(chunk, into: &buffer, continuation: continuation)
                }

                emitLine(&buffer, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                try? handle.close()
            }
        }
    }

    /// Decode the buffered line lossily so a single invalid UTF-8 byte never silently drops an
    /// entire line (which could be a terminal `result`), then reset the buffer.
    private static func emitLine(
        _ buffer: inout Data,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard !buffer.isEmpty else { return }
        continuation.yield(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll(keepingCapacity: true)
    }

    private static func appendChunk(
        _ chunk: Data,
        into buffer: inout Data,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            if let nlIndex = chunk[cursor..<chunk.endIndex].firstIndex(of: newline) {
                appendStripped(chunk[cursor..<nlIndex], into: &buffer)
                emitLine(&buffer, continuation: continuation)
                cursor = chunk.index(after: nlIndex)
            } else {
                appendStripped(chunk[cursor..<chunk.endIndex], into: &buffer)
                if buffer.count > maxLineBytes {
                    // Oversized line with no newline: flush what we have to bound memory.
                    emitLine(&buffer, continuation: continuation)
                }
                break
            }
        }
    }

    private static func appendStripped(_ segment: Data.SubSequence, into buffer: inout Data) {
        guard !segment.isEmpty else { return }
        if segment.contains(carriageReturn) {
            buffer.append(contentsOf: segment.lazy.filter { $0 != carriageReturn })
        } else {
            buffer.append(contentsOf: segment)
        }
    }
}
