///|
/// Prints the base block of a hive, its key tree, every value, builds a demo
/// hive, or imports a .reg document into a hive.
///
/// usage: moon run cmd/main -- <hive file> [--values]
///        moon run cmd/main -- --build [output.hive]
///        moon run cmd/main -- --import-reg <input.reg> <output.hive>
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run cmd/main -- <hive file> [--values]")
    println("       moon run cmd/main -- --build [output.hive]")
    println(
      "       moon run cmd/main -- --import-reg <input.reg> <output.hive>",
    )
    return
  }
  if args[1] == "--build" {
    run_build(args)
    return
  }
  if args[1] == "--import-reg" {
    run_import_reg(args)
    return
  }
  if args[1] == "--export-reg" {
    run_export_reg(args)
    return
  }
  if args[1] == "--replay-log" {
    run_replay_log(args)
    return
  }
  run_inspect(args)
}

///|
/// Prints the base block fields of a hive.
fn print_header(path : String, header : @moonregf.HiveHeader) -> Unit {
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
}

///|
/// Prints every value reachable from the root key.
fn print_values(data : Bytes, entries : Array[@moonregf.HiveKeyEntry]) -> Unit {
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
}

///|
/// Prints the header and the tree or every value of a hive file.
fn run_inspect(args : Array[String]) -> Unit {
  let path = args[1]
  let want_values = args.length() >= 3 && args[2] == "--values"
  try {
    let data = @fs.read_file_to_bytes(path)
    match @moonregf.parse_header(data) {
      Ok(header) => {
        print_header(path, header)
        let entries = @moonregf.walk_key_tree(data, header.root_cell_offset, 3)
        if want_values {
          print_values(data, entries)
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

///|
/// Writes a demo hive built from a small key tree.
fn run_build(args : Array[String]) -> Unit {
  let target = if args.length() >= 3 { args[2] } else { "demo.hive" }
  let builder = @moonregf.HiveBuilder::new()
  let software = builder.add_key(0, "Software")
  let vendor = builder.add_key(software, "Vendor")
  builder.set_string(software, "Install", "Hello moonregf")
  builder.set_dword(software, "Count", 42)
  builder.set_string(vendor, "Name", "Demo")
  match builder.build() {
    Ok(bytes) =>
      try {
        @fs.write_bytes_to_file(target, bytes)
        println(
          "wrote " +
          target +
          " (" +
          bytes.length().to_string() +
          " bytes, " +
          builder.key_count().to_string() +
          " keys)",
        )
      } catch {
        @fs.IOError::IOError(message) => println("I/O error: " + message)
      }
    Err(error) => println("error: " + error.message())
  }
}

///|
/// Imports a .reg document into a fresh hive file.
fn run_import_reg(args : Array[String]) -> Unit {
  if args.length() < 4 {
    println(
      "usage: moon run cmd/main -- --import-reg <input.reg> <output.hive>",
    )
    return
  }
  try {
    let raw = @fs.read_file_to_bytes(args[2])
    match @moonregf.parse_reg_bytes(raw) {
      Err(error) => println("error: " + error.message())
      Ok(file) =>
        match file.to_builder() {
          Err(error) => println("error: " + error.message())
          Ok(builder) =>
            match builder.build() {
              Err(error) => println("error: " + error.message())
              Ok(bytes) => {
                @fs.write_bytes_to_file(args[3], bytes)
                println(
                  "imported " +
                  file.section_count().to_string() +
                  " sections and " +
                  file.value_count().to_string() +
                  " values into " +
                  args[3],
                )
              }
            }
        }
    }
  } catch {
    @fs.IOError::IOError(message) => println("I/O error: " + message)
  }
}

///|
/// Exports a hive as .reg text.
fn run_export_reg(args : Array[String]) -> Unit {
  if args.length() < 4 {
    println(
      "usage: moon run cmd/main -- --export-reg <input.hive> <output.reg> [root] ",
    )
    return
  }
  let root = if args.length() >= 5 { args[4] } else { "" }
  try {
    let data = @fs.read_file_to_bytes(args[2])
    match @moonregf.export_reg_text(data, root) {
      Err(error) => println("error: " + error.message())
      Ok(text) => {
        @fs.write_string_to_file(args[3], text)
        println(
          "exported to " +
          args[3] +
          " (" +
          text.length().to_string() +
          " chars)",
        )
      }
    }
  } catch {
    @fs.IOError::IOError(message) => println("I/O error: " + message)
  }
}

///|
/// Replays a transaction log onto a hive and writes the patched copy.
fn run_replay_log(args : Array[String]) -> Unit {
  if args.length() < 4 {
    println(
      "usage: moon run cmd/main -- --replay-log <input.hive> <input.LOG1> [output.hive]",
    )
    return
  }
  let target = if args.length() >= 5 { args[4] } else { args[2] + ".replayed" }
  try {
    let hive = @fs.read_file_to_bytes(args[2])
    let log = @fs.read_file_to_bytes(args[3])
    match @moonregf.replay_log(hive, log) {
      Err(error) => println("error: " + error.message())
      Ok(replay) => {
        @fs.write_bytes_to_file(target, replay.bytes)
        println(
          "replayed " +
          replay.applied.to_string() +
          " entries up to sequence " +
          replay.final_sequence.to_string() +
          " into " +
          target,
        )
      }
    }
  } catch {
    @fs.IOError::IOError(message) => println("I/O error: " + message)
  }
}
