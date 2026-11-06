///|
/// Prints the base block and the key tree of a registry hive file.
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
        let entries = @moonregf.walk_key_tree(data, header.root_cell_offset, 3)
        println("tree (depth 3):")
        let mut index = 0
        while index < entries.length() {
          println(entries[index].path)
          index = index + 1
        }
        println("tree keys  : " + entries.length().to_string())
      }
      Err(error) => println("error: " + error.message())
    }
  } catch {
    @fs.IOError::IOError(message) => println("I/O error: " + message)
  }
}
