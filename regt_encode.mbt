///|
/// Encodes text as UTF-16LE code units.
pub fn encode_utf16le(text : String) -> Bytes {
  let source = @utf8.encode(text)
  let out : Array[Byte] = []
  let size = source.length()
  let mut index = 0
  while index < size {
    let b0 = source[index].to_int()
    let mut code = 0xFFFD
    let mut width = 1
    if b0 < 0x80 {
      code = b0
    } else if b0 >= 0xC2 && b0 <= 0xDF && index + 1 < size {
      code = ((b0 & 0x1F) << 6) | (source[index + 1].to_int() & 0x3F)
      width = 2
    } else if b0 >= 0xE0 && b0 <= 0xEF && index + 2 < size {
      code = ((b0 & 0x0F) << 12) |
        ((source[index + 1].to_int() & 0x3F) << 6) |
        (source[index + 2].to_int() & 0x3F)
      width = 3
    } else if b0 >= 0xF0 && b0 <= 0xF4 && index + 3 < size {
      code = ((b0 & 0x07) << 18) |
        ((source[index + 1].to_int() & 0x3F) << 12) |
        ((source[index + 2].to_int() & 0x3F) << 6) |
        (source[index + 3].to_int() & 0x3F)
      width = 4
    }
    if code < 0x10000 {
      out.push((code & 0xFF).to_byte())
      out.push(((code >> 8) & 0xFF).to_byte())
    } else {
      let adjusted = code - 0x10000
      let high = 0xD800 + (adjusted >> 10)
      let low = 0xDC00 + (adjusted & 0x3FF)
      out.push((high & 0xFF).to_byte())
      out.push(((high >> 8) & 0xFF).to_byte())
      out.push((low & 0xFF).to_byte())
      out.push(((low >> 8) & 0xFF).to_byte())
    }
    index = index + width
  }
  Bytes::from_array(out)
}
