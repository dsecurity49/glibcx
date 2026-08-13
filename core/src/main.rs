use glibcx_core::{Mode, PROTOCOL, VERSION, inspect};

fn usage() -> ! {
    eprintln!("Usage: glibcx-core handshake | inspect <target|dso> <path>");
    std::process::exit(2);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [command] if command == "handshake" => {
            println!("{{\"protocol\":{PROTOCOL},\"version\":\"{VERSION}\"}}")
        }
        [command, mode, path] if command == "inspect" => match Mode::parse(mode) {
            Some(mode) => println!("{}", inspect(path, mode)),
            None => usage(),
        },
        _ => usage(),
    }
}
