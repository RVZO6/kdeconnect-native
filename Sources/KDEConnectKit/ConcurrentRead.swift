/// Runs independent reads with a bounded number of tasks. Results keep input order,
/// including optional results, even when requests complete out of order.
/// A new task starts only when an earlier task completes.
func concurrentRead<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], limit: Int,
    operation: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    precondition(limit > 0)
    return await withTaskGroup(of: (Int, Output).self) { group in
        var iterator = inputs.enumerated().makeIterator()
        var results = [Output?](repeating: nil, count: inputs.count)
        for _ in 0..<min(limit, inputs.count) {
            guard let (index, input) = iterator.next() else { break }
            group.addTask { (index, await operation(input)) }
        }
        while let (index, output) = await group.next() {
            // Output can itself be Optional. Keep an explicit outer .some.
            results[index] = .some(output)
            if let (nextIndex, input) = iterator.next() {
                group.addTask { (nextIndex, await operation(input)) }
            }
        }
        return results.map { $0! }
    }
}
