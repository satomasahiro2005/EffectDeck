//  URLSessionBytes.swift（Linuxの代役）
//  URLSession.bytes(for:)はDarwinだけにある（LinuxのFoundationNetworkingに無い）。
//  ETRemoteFileが使うので、同じ名前で本文を全部受けてから1バイトずつ渡すものを置く。
//  `bytes.task.cancel()`も通るよう、受けたdataTaskを持たせる（受け終わった後なので何もしない）。
//  **テストは網へ出ない。**建てるためのもので、落とす順番（途中で上限を超えたら止める）は
//  Linuxでは確かめられない。**このフォルダはテストのモジュールへ直接入る。**

import Foundation
import FoundationNetworking

extension URLSession {
    struct AsyncBytes: AsyncSequence {
        typealias Element = UInt8
        let data: Data
        let task: URLSessionDataTask

        struct AsyncIterator: AsyncIteratorProtocol {
            let data: Data
            var index: Data.Index
            mutating func next() async throws -> UInt8? {
                guard index < data.endIndex else { return nil }
                defer { index = data.index(after: index) }
                return data[index]
            }
        }

        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(data: data, index: data.startIndex) }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDataTask?
    }

    func bytes(for request: URLRequest,
               delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (AsyncBytes, URLResponse) {
        let box = TaskBox()
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { done in
            let task = dataTask(with: request) { data, response, error in
                if let error {
                    done.resume(throwing: error)
                } else if let response {
                    done.resume(returning: (data ?? Data(), response))
                } else {
                    done.resume(throwing: URLError(.badServerResponse))
                }
            }
            box.task = task
            task.resume()
        }
        return (AsyncBytes(data: data, task: box.task!), response)
    }

    func bytes(from url: URL,
               delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (AsyncBytes, URLResponse) {
        try await bytes(for: URLRequest(url: url), delegate: delegate)
    }
}
