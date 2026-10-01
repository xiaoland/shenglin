// 仅测量候选快照的编码上限；不是生产协议、签名实现或兼容性承诺。
import Foundation

struct Source: Codable {
    let i: Data // 本设备命名空间内的 128 位来源实例 ID。
    let q: UInt8 // 0 无请求，1 请求背景衰减，2 状态未知。
    let a: Data? // 用户或应用集成明确建立的 128 位关联 ID。
}
struct Snapshot: Codable {
    let v: UInt8
    let o: String
    let r: UInt64
    let e: Int64
    let k: UInt8
    let s: [Source]
    let h: Data // 32 字节签名占位；验证时需使用独立签名域。
}
struct WiFiFrame: Codable { let kind: String; let update: Snapshot }

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let sources = (0..<4).map { number -> Source in
    var id = Data(repeating: 255, count: 16)
    id[15] = UInt8(number)
    return Source(i: id, q: 2, a: Data(repeating: 255, count: 16))
}
let snapshot = Snapshot(v: 1, o: "initiator", r: .max, e: .max, k: 0,
                        s: sources, h: Data(repeating: 255, count: 32))
let data = try encoder.encode(snapshot)
let wifi = try encoder.encode(WiFiFrame(kind: "update", update: snapshot))
assert(data.count <= 512 && wifi.count <= 1024)
let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
assert(decoded.s.count == 4 && decoded.s.allSatisfy { $0.i.count == 16 && $0.a?.count == 16 })
assert(decoded.h.count == 32 && decoded.r == UInt64.max)
print("四个均带关联的来源：BLE \(data.count)/512 字节，Wi-Fi 外层 \(wifi.count)/1024 字节。")
