///|
/// Decodes unit_count UTF-16LE code units starting at byte offset.
///
/// Decoding stops at the first NUL code unit, matching how REGF stores the
/// fixed-width base block file name. Unpaired surrogates become U+FFFD so the
/// result is always valid UTF-8.
pub fn decode_utf16le(
  bytes : Bytes,
  offset : Int32,
  unit_count : Int32,
) -> String {
  let out : Array[Byte] = []
  let mut index = 0
  while index < unit_count {
    let lo = bytes[offset + index * 2].to_int()
    let hi = bytes[offset + index * 2 + 1].to_int()
    let unit = lo | (hi << 8)
    if unit == 0 {
      break
    }
    let mut code = unit
    if unit >= 0xD800 && unit <= 0xDBFF && index + 1 < unit_count {
      let lo2 = bytes[offset + (index + 1) * 2].to_int()
      let hi2 = bytes[offset + (index + 1) * 2 + 1].to_int()
      let low = lo2 | (hi2 << 8)
      if low >= 0xDC00 && low <= 0xDFFF {
        code = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
        index = index + 1
      }
    }
    if code >= 0xD800 && code <= 0xDFFF {
      code = 0xFFFD
    }
    if code < 0x80 {
      out.push((code & 0xFF).to_byte())
    } else if code < 0x800 {
      out.push((0xC0 | (code >> 6)).to_byte())
      out.push((0x80 | (code & 0x3F)).to_byte())
    } else if code < 0x10000 {
      out.push((0xE0 | (code >> 12)).to_byte())
      out.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (code & 0x3F)).to_byte())
    } else {
      out.push((0xF0 | (code >> 18)).to_byte())
      out.push((0x80 | ((code >> 12) & 0x3F)).to_byte())
      out.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (code & 0x3F)).to_byte())
    }
    index = index + 1
  }
  let encoded = Bytes::from_array(out)
  @utf8.decode_lossy(encoded.clamped_view(start=0, end=encoded.length()))
}
