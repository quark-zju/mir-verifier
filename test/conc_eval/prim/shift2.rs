#![cfg_attr(not(with_main), no_std)]
fn f(x: u8) -> u8 {
    x << 1i32
}

const ARG: u8 = 1;

#[cfg(with_main)]
pub fn main() {
    println!("{:?}", f(ARG));
}
#[cfg(not(with_main))] pub fn main() { f(ARG); }
