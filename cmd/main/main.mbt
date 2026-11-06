///|
/// Prints the base block of a hive and either its key tree or every value.
///
/// usage: moon run cmd/main -- <hive file> [--values]
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run cmd/main -- <hive file> [--values]")
    return
  }
  let path = args[1]
  let want_values = args.length() >= 3 && args[2] == "--values"
  try {
    let data = @fs.read_file_to_bytes(path)
    match @moonregf.parse_header(data) {
      Ok(header) => {
        println("file       : " + path)
        println("signature  : regf")
        println(
          "sequence   : " +
          header.primary_sequence.to_string() +
          " / " +
          header.secondary_sequence.to_string(),
        )
        println(
          "version    : " +
          header.major_version.to_string() +
          "." +
          header.minor_version.to_string(),
        )
        println("file type  : " + header.file_type.label())
        println("root cell  : " + header.root_cell_offset.to_string())
        println("bins size  : " + header.hive_bins_data_size.to_string())
        println("name       : " + header.file_name)
        println("checksum   : 0x" + header.checksum.to_string(radix=16))
        let entries = @moonregf.walk_key_tree(data, header.root_cell_offset, 3)
        if want_values {
          let mut total = 0
          let mut skipped = 0
          let mut index = 0
          while index < entries.length() {
            let entry = entries[index]
            match @moonregf.parse_key_node(data, entry.offset) {
              Ok(key) =>
                match @moonregf.value_offsets(data, key) {
                  Ok(offsets) => {
                    let mut inner = 0
                    while inner < offsets.length() {
                      match @moonregf.parse_value(data, offsets[inner]) {
                        Ok(value) => {
                          println(
                            entry.path +
                            " | " +
                            value.name +
                            " | " +
                            value.data_type.label() +
                            " | " +
                            value.data.length().to_string(),
                          )
                          total = total + 1
                        }
                        Err(_) => skipped = skipped + 1
                      }
                      inner = inner + 1
                    }
                  }
                  Err(_) => skipped = skipped + 1
                }
              Err(_) => ()
            }
            index = index + 1
          }
          println("values     : " + total.to_string())
          println("skipped    : " + skipped.to_string())
        } else {
          println("tree (depth 3):")
          let mut index = 0
          while index < entries.length() {
            println(entries[index].path)
            index = index + 1
          }
          println("tree keys  : " + entries.length().to_string())
        }
      }
      Err(error) => println("error: " + error.message())
    }
  } catch {
    @fs.IOError::IOError(message) => println("I/O error: " + message)
  }
}
