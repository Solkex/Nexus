-- Verifies the base64+JSON codec round-trips correctly, matches known
-- vectors, and safely rejects malformed/oversized/malicious input.
dofile("tests/harness.lua")
dofile("core/Codec.lua")
local Codec = Nexus.Codec

-- Base64 known vectors (standard RFC 4648 test vectors)
assert(Codec.Base64Encode("") == "")
assert(Codec.Base64Encode("f") == "Zg==")
assert(Codec.Base64Encode("fo") == "Zm8=")
assert(Codec.Base64Encode("foo") == "Zm9v")
assert(Codec.Base64Encode("foobar") == "Zm9vYmFy")
print("base64 encode matches known RFC 4648 vectors -- OK")

assert(Codec.Base64Decode("Zg==") == "f")
assert(Codec.Base64Decode("Zm9vYmFy") == "foobar")
print("base64 decode matches known vectors -- OK")

-- round trip on binary-ish and unicode-ish data
for _, s in ipairs({ "", "a", "ab", "abc", "abcd", "Hello, World! 123",
    string.rep("x", 500), "\1\2\3\0\255" }) do
    local decoded = Codec.Base64Decode(Codec.Base64Encode(s))
    assert(decoded == s, "round-trip failed for length " .. #s)
end
print("base64 round-trips correctly across a range of lengths -- OK")

-- malformed base64 must return nil, never error
assert(Codec.Base64Decode("not valid!!!") == nil)
assert(Codec.Base64Decode("abc") == nil)  -- not a multiple of 4
assert(Codec.Base64Decode(nil) == nil)
assert(Codec.Base64Decode(12345) == nil)
print("malformed base64 input safely rejected -- OK")

-- JSON round trip
local data = { title = "Fire Mage AoE", class = "MAGE", spec = 1,
    comments = "Great build!\nLine two.", echoes = {
        { spellId = 200100, quality = 3, stacks = 1 },
        { spellId = 200104, quality = 2, stacks = 9 },
    }, empty = {}, flag = true, nothing = nil }
local json = Codec.JSONEncode(data)
local back = Codec.JSONDecode(json)
assert(back.title == "Fire Mage AoE")
assert(back.class == "MAGE")
assert(back.comments == "Great build!\nLine two.")
assert(#back.echoes == 2)
assert(back.echoes[1].spellId == 200100)
assert(back.echoes[2].stacks == 9)
assert(back.flag == true)
print("JSON round-trips complex nested structures correctly -- OK")

-- special characters that must survive encoding (quotes, backslashes, unicode escape)
local special = { text = 'Quote " and backslash \\ and tab\tend' }
local roundtrip = Codec.JSONDecode(Codec.JSONEncode(special))
assert(roundtrip.text == special.text, "special characters did not survive JSON round-trip")
print("special characters (quotes, backslashes, tabs) survive JSON round-trip -- OK")

-- malformed/malicious JSON must never error, only return nil or garbage safely
assert(Codec.JSONDecode("") == nil)
assert(Codec.JSONDecode(nil) == nil)
local ok1 = pcall(Codec.JSONDecode, "{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{")
assert(ok1, "deeply nested garbage JSON should not error")
local ok2 = pcall(Codec.JSONDecode, string.rep("[", 10000))
assert(ok2, "pathologically deep nesting should not error/hang")
print("malformed/malicious JSON safely handled without erroring -- OK")

-- IsSafeTree bounds check
assert(Codec.IsSafeTree({ a = 1, b = { c = 2 } }, 8, 5000) == true)
local deep = {}
local cursor = deep
for i = 1, 20 do cursor.child = {}; cursor = cursor.child end
assert(Codec.IsSafeTree(deep, 8, 5000) == false, "overly deep tree should fail the safety check")
local wide = {}
for i = 1, 10000 do wide[i] = i end
assert(Codec.IsSafeTree(wide, 8, 5000) == false, "overly wide tree should fail the safety check")
print("IsSafeTree correctly bounds depth and breadth -- OK")

print("codec fully verified (encode/decode/round-trip/safety)")
