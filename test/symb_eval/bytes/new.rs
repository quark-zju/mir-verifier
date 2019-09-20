#![cfg_attr(not(with_main), no_std)]
#![feature(custom_attribute)]

extern crate bytes;
use bytes::{Bytes, BytesMut, Buf, BufMut};

#[crux_test]
pub fn f() {
    let mut b = BytesMut::new();
    assert!(b.len() == 0);
    assert!(b.is_empty());
    assert!(b.freeze().len() == 0);
}


#[cfg(with_main)] pub fn main() { println!("{:?}", f()); }