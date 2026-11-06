///|
/// Prints the base block and the root key of a registry hive file.
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run cmd/main -- <hive file>")
    return
  }
  let path = args[args.length() - 1]
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
        match @moonregf.parse_key_node(data, header.root_cell_offset) {
          Ok(key) => {
            println("root key   : " + key.name)
            println("subkeys    : " + key.subkey_count.to_string())
            println("values     : " + key.value_count.to_string())
          }
          Err(error) => println("root key   : error: " + error.message())
        }
      }
      Err(error) => println("error: " + error.message())
    }
  } catch {
    @fs.IOError::IOError(message) => println("I/O error: " + message)
  }
}
