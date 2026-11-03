//  RemoteFileFuzz.swift（Tests/Fuzz）
//  的 remotefile: 貼られたリンクの読み替え（ETRemoteFile.address(from:)）と gist の名前選び。
//  網には出ない（download は叩かない）。
//
//  約束:
//    - 読み替えた先は http か https で、host がある
//    - **読み替えは 1 度で済む。**読み替えた先をもう一度渡しても同じ所を指す
//    - gist の API を指すなら path は /gists/<id>
//    - gistAnchor は英小文字・数字・`_`・`-` だけで、`-` は続かない
//    - 名前を選ぶ関数は渡した名前のどれかを返す（無ければ nil）
//    - gist の画面から拾った Raw の行き先は gist.github.com で、名前は重ならない

import Foundation

enum RemoteFileFuzz {
    private static let anchorCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")

    static func run(_ data: UnsafeRawBufferPointer) {
        let text = Fuzz.text(data)

        if let url = ETRemoteFile.address(from: text) {
            let scheme = url.scheme?.lowercased()
            Fuzz.oracle(scheme == "http" || scheme == "https", "読み替えた先の scheme: \(url.absoluteString)")
            // **既知（報告済み・未修正）:** host が空のリンク（`https:///blob/x`）を address(from:) が通す。
            // URLComponents の host は nil でなく "" なので guard を抜ける。落ちはせず、download が網の
            // 失敗で断る（「リンクに見えない」とは言わない）。ETRemoteFile.swift は P-Share の持ち物なので
            // ここでは直さない。直ったらこの例外を外す。
            let emptyHost = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host == ""
            Fuzz.oracle(url.host.map { !$0.isEmpty } ?? false || emptyHost,
                        "読み替えた先に host が無い: \(url.absoluteString)")
            // gist の画面から読み替えた API は /gists/<id> で、id は空でない。
            // **貼られた api.github.com はそのまま通す（設計どおり）ので見ない。**`https://api.github.com/gists/`
            // を貼ると同じ字が返る（的が最初に拾った誤報）。path は URL.path で見ない
            // （Linux の Foundation は末尾の / を落とす）。
            let pastedHost = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?
                .host?.lowercased()
            if pastedHost == "gist.github.com", url.host == "api.github.com" {
                let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                Fuzz.oracle(parts.count == 3 && parts[0].isEmpty && parts[1] == "gists" && !parts[2].isEmpty,
                            "gist の API の path: \(url.absoluteString)")
            }
            let again = ETRemoteFile.address(from: url.absoluteString)
            Fuzz.oracle(again?.absoluteString == url.absoluteString,
                        "読み替えが 1 度で済まない: \(url.absoluteString) → \(again?.absoluteString ?? "nil")")
        }

        let anchor = ETRemoteFile.gistAnchor(for: text)
        Fuzz.oracle(anchor.allSatisfy { anchorCharacters.contains($0) } && !anchor.contains("--"),
                    "gistAnchor の字: \(anchor)")

        let names = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        let first = ETRemoteFile.firstGistFile(among: names)
        Fuzz.oracle(names.isEmpty ? first == nil : first.map(names.contains) == true,
                    "firstGistFile が一覧に無い名前を返した")
        if let wanted = names.first {
            let hit = ETRemoteFile.gistFile(named: ETRemoteFile.gistAnchor(for: wanted), among: names)
            Fuzz.oracle(hit.map(names.contains) ?? true, "gistFile が一覧に無い名前を返した")
        }

        let id = names.first.map { String($0.prefix(40)) } ?? "0123abcd"
        let links = ETRemoteFile.gistRawLinks(inPage: text, id: id)
        Fuzz.oracle(Set(links.map(\.name)).count == links.count, "gistRawLinks の名前が重なる")
        for link in links {
            Fuzz.oracle(link.raw.host == "gist.github.com", "gistRawLinks の行き先: \(link.raw.absoluteString)")
        }
    }
}
