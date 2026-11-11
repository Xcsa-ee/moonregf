///|
/// SID string round trip.
fn sk_sid(text : String) -> String {
  match sid_from_string(text) {
    Err(error) => "err " + error.message()
    Ok(bytes) => sid_to_string(bytes, 0)
  }
}

///|
test "round trips a SID string" {
  assert_eq(sk_sid("S-1-5-18"), "S-1-5-18")
  assert_eq(sk_sid("S-1-5-21-1-2-3"), "S-1-5-21-1-2-3")
}

///|
test "writes and reads a security descriptor" {
  let builder = HiveBuilder::new()
  match security_descriptor_with_owner_group("S-1-5-18", "S-1-5-19") {
    Err(error) => assert_eq(error.message(), "built")
    Ok(descriptor) => {
      builder.set_security(0, descriptor)
      match builder.build() {
        Err(error) => assert_eq(error.message(), "built")
        Ok(bytes) =>
          match parse_header(bytes) {
            Err(error) => assert_eq(error.message(), "header")
            Ok(header) =>
              match parse_key_node(bytes, header.root_cell_offset) {
                Err(error) => assert_eq(error.message(), "key")
                Ok(key) =>
                  match describe_security(bytes, key) {
                    Err(error) => assert_eq(error.message(), "security")
                    Ok(parsed) => {
                      assert_eq(parsed.owner, "S-1-5-18")
                      assert_eq(parsed.group, "S-1-5-19")
                      assert_eq(parsed.has_dacl, false)
                    }
                  }
              }
          }
      }
    }
  }
}

///|
test "reports a key without a security descriptor" {
  let builder = HiveBuilder::new()
  match builder.build() {
    Err(error) => assert_eq(error.message(), "built")
    Ok(bytes) =>
      match parse_header(bytes) {
        Err(error) => assert_eq(error.message(), "header")
        Ok(header) =>
          match parse_key_node(bytes, header.root_cell_offset) {
            Err(error) => assert_eq(error.message(), "key")
            Ok(key) =>
              match describe_security(bytes, key) {
                Err(error) =>
                  assert_eq(
                    error.message().has_suffix("the key has no sk record"),
                    true,
                  )
                Ok(_) => assert_eq("decoded", "rejected")
              }
          }
      }
  }
}
