import Foundation
@testable import NyutagCore
import Testing

@Suite struct JSONValueTests {
    @Test func parsesAndAccesses() throws {
        let json = try JSONValue(parsing: #"{"a":1,"b":[true,"x",2.5],"c":{"d":null},"big":1760000000000}"#)
        #expect(json["a"]?.int == 1)
        #expect(json["b"]?[0]?.bool == true)
        #expect(json["b"]?[1]?.string == "x")
        #expect(json["b"]?[2]?.double == 2.5)
        #expect(json["c", "d"]?.isNull == true)
        #expect(json["big"]?.int == 1_760_000_000_000)
        #expect(json["missing"] == nil)
    }

    @Test func canonicalJSONMatchesSpec() throws {
        // Примеры из приложения спецификации Matrix «Canonical JSON».
        #expect(try JSONValue(parsing: #"{"b":"2","a":"1"}"#).canonicalJSON() == #"{"a":"1","b":"2"}"#)
        #expect(try JSONValue(parsing: #"{"本":2,"日":1}"#).canonicalJSON() == #"{"日":1,"本":2}"#)
        #expect(try JSONValue(parsing: #"{"a":"日"}"#).canonicalJSON() == #"{"a":"日"}"#)
        #expect(try JSONValue(parsing: #"{"a":null}"#).canonicalJSON() == #"{"a":null}"#)
        #expect(try JSONValue(parsing: #"{"a":"\n","b":"\u0000"}"#).canonicalJSON() == #"{"a":"\n","b":"\u0000"}"#)
        #expect(try JSONValue(parsing: #"[{"z":1,"y":[2,{"x":3}]}]"#).canonicalJSON() == #"[{"y":[2,{"x":3}],"z":1}]"#)
    }

    @Test func roundTripsThroughData() throws {
        let value: JSONValue = ["type": "m.room.message", "content": ["body": "Сайн байна", "n": 7, "ok": true]]
        let data = try value.data()
        #expect(try JSONValue(data: data) == value)
    }
}
