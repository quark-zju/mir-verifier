#![cfg_attr(not(with_main), no_std)]
#[cfg_attr(with_main, derive(Debug))]
struct S {
    x: u8,
    y: i32,
}

fn f(s: S) -> u8 {
    s.x
}

const ARG: S = S { x: 42, y: 120 };

#[cfg(with_main)]
pub fn main() {
    println!("{:?}", f(ARG));
}
#[cfg(not(with_main))] pub fn main() { f(ARG); }
