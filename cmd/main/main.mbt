///|
/// Prints the base block of a registry hive file.
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
        println("format     : " + header.file_format.to_string())
        println("root cell  : " + header.root_cell_offset.to_string())
        println("bins size  : " + header.hive_bins_data_size.to_string())
        println("clustering : " + header.clustering_factor.to_string())
        println("name       : " + header.file_name)
        println("checksum   : 0x" + header.checksum.to_string(radix=16))
      }
      Err(error) => println("error: " + error.message())
    }
  } catch {
    @fs.IOError::IOError(message) => println("I/O error: " + message)
  }
}
