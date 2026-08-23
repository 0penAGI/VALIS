import Foundation

func topK<T>(_ values: [T], count limit: Int, by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
    let target = min(max(limit, 0), values.count)
    guard target > 0 else { return [] }

    if values.count <= target {
        return values.sorted(by: areInIncreasingOrder)
    }

    var selected: [T] = []
    selected.reserveCapacity(target)

    for value in values {
        if selected.count < target {
            selected.append(value)
            continue
        }

        var worstIndex = 0
        if selected.count > 1 {
            for index in 1..<selected.count {
                if areInIncreasingOrder(selected[worstIndex], selected[index]) {
                    worstIndex = index
                }
            }
        }

        if areInIncreasingOrder(value, selected[worstIndex]) {
            selected[worstIndex] = value
        }
    }

    return selected.sorted(by: areInIncreasingOrder)
}
