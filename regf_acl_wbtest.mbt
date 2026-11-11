///|
/// Builds a self-relative descriptor holding one allow ACE for SYSTEM.
fn acl_sample() -> Bytes {
  let owner = match sid_from_string("S-1-5-18") {
    Err(_) => Bytes::new(0)
    Ok(parsed) => parsed
  }
  let group = match sid_from_string("S-1-5-18") {
    Err(_) => Bytes::new(0)
    Ok(parsed) => parsed
  }
  let ace_size = 8 + 12
  let acl_size = 8 + ace_size
  let dacl_offset = 20 + owner.length() + group.length()
  let out : Array[Byte] = []
  out.push((1).to_byte())
  out.push((0).to_byte())
  out.push((0x04).to_byte())
  out.push((0x80).to_byte())
  push_u32(out, 20)
  push_u32(out, 20 + owner.length())
  push_u32(out, 0)
  push_u32(out, dacl_offset)
  let mut index = 0
  while index < owner.length() {
    out.push(owner[index])
    index = index + 1
  }
  index = 0
  while index < group.length() {
    out.push(group[index])
    index = index + 1
  }
  out.push((2).to_byte())
  out.push((0).to_byte())
  out.push((acl_size & 0xFF).to_byte())
  out.push(((acl_size >> 8) & 0xFF).to_byte())
  out.push((1).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((0).to_byte())
  out.push((ace_size & 0xFF).to_byte())
  out.push(((ace_size >> 8) & 0xFF).to_byte())
  push_u32(out, 0x10000000)
  index = 0
  while index < owner.length() {
    out.push(owner[index])
    index = index + 1
  }
  Bytes::from_array(out)
}

///|
test "parses an access control entry" {
  let bytes = acl_sample()
  match parse_security_descriptor(bytes, 0) {
    Err(error) => assert_eq(error.message(), "parsed")
    Ok(descriptor) => {
      assert_eq(descriptor.owner, "S-1-5-18")
      assert_eq(descriptor.has_dacl, true)
      assert_eq(descriptor.has_sacl, false)
      assert_eq(descriptor.dacl.length(), 1)
      assert_eq(descriptor.dacl[0].ace_type.label(), "ACCESS_ALLOWED")
      assert_eq(descriptor.dacl[0].mask, (0x10000000 : UInt32))
      assert_eq(descriptor.dacl[0].sid, "S-1-5-18")
    }
  }
}

///|
test "rejects a truncated ACL" {
  let bytes = acl_sample()
  let cut = copy_range(bytes, 0, bytes.length() - 8)
  match parse_security_descriptor(cut, 0) {
    Err(error) => assert_eq(error.message(), "parsed")
    Ok(descriptor) => assert_eq(descriptor.dacl.length(), 0)
  }
}
