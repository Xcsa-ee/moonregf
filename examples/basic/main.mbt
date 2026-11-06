///|
/// Builds a small hive in memory, reads it back and prints every key and value.
///
/// Run with: moon run examples/basic
fn main {
  let builder = @moonregf.HiveBuilder::new()
  let software = builder.add_key(0, "Software")
  let vendor = builder.add_key(software, "Vendor")
  builder.set_string(software, "Install", "Hello moonregf")
  builder.set_dword(software, "Count", 42)
  builder.set_string(vendor, "Name", "Demo")
  match builder.build() {
    Err(error) => println("build failed: " + error.message())
    Ok(bytes) => {
      println("built a hive of " + bytes.length().to_string() + " bytes")
      match @moonregf.parse_header(bytes) {
        Err(error) => println("parse failed: " + error.message())
        Ok(header) => {
          println("checksum 0x" + header.checksum.to_string(radix=16))
          let entries = @moonregf.walk_key_tree(
            bytes,
            header.root_cell_offset,
            8,
          )
          let mut index = 0
          while index < entries.length() {
            let entry = entries[index]
            println("key   " + entry.path)
            match @moonregf.parse_key_node(bytes, entry.offset) {
              Err(error) => println("      error: " + error.message())
              Ok(key) =>
                match @moonregf.list_values(bytes, key) {
                  Err(error) => println("      error: " + error.message())
                  Ok(values) => {
                    let mut inner = 0
                    while inner < values.length() {
                      println(
                        "      " +
                        values[inner].name +
                        " = " +
                        values[inner].data_type.label(),
                      )
                      inner = inner + 1
                    }
                  }
                }
            }
            index = index + 1
          }
        }
      }
    }
  }
}
