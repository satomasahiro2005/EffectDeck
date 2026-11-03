//  PEQTextFuzz.swift（Tests/Fuzz）
//  的 peqtext: 15Band PEQ の Import（ETPEQTextImport.decode → parse）。
//
//  約束:
//    - バンドはいつも 15 本、取り込んだ数は 0...15
//    - 値は有限で setBand の範囲の中（周波数 20〜20000、ゲイン -20〜20、
//      Q 0.1〜10、シェルフは 2 まで）、型の添字は filterTypeIDs の中
//    - 取り込んだバンドは点いていて、残りは取り込む前の形（resetBand）のまま

import Foundation

enum PEQTextFuzz {
    static func run(_ data: UnsafeRawBufferPointer) {
        let result = ETPEQTextImport.parse(ETPEQTextImport.decode(Data(data)))
        Fuzz.oracle(result.bands.count == ETPEQTextImport.bandCount, "バンドの数 \(result.bands.count)")
        Fuzz.oracle((0...ETPEQTextImport.bandCount).contains(result.imported), "取り込んだ数 \(result.imported)")
        for (i, band) in result.bands.enumerated() {
            Fuzz.oracle(ETPEQTextImport.filterTypeIDs.indices.contains(band.type), "バンド \(i) の型 \(band.type)")
            let shelf = ["ls", "hs"].contains(ETPEQTextImport.filterTypeIDs[band.type])
            Fuzz.oracle(band.frequency.isFinite && (20...20000).contains(band.frequency),
                        "バンド \(i) の周波数 \(band.frequency)")
            Fuzz.oracle(band.gain.isFinite && (-20...20).contains(band.gain), "バンド \(i) のゲイン \(band.gain)")
            Fuzz.oracle(band.q.isFinite && band.q >= 0.1 && band.q <= (shelf ? 2 : 10), "バンド \(i) の Q \(band.q)")
            if i < result.imported {
                Fuzz.oracle(band.enabled, "取り込んだバンド \(i) が切れている")
            } else {
                Fuzz.oracle(band == ETPEQTextImport.resetBand(i), "取り込んでいないバンド \(i) が変わった")
            }
        }
    }
}
