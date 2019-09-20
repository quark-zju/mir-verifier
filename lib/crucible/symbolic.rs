pub trait Symbolic {
    fn symbolic(desc: &'static str) -> Self;
}


macro_rules! uint_impls {
    ($($ty:ty, $func:ident;)*) => {
        $(
            /// Hook for a crucible override that creates a symbolic instance of $ty.
            fn $func(desc: &'static str) -> $ty { unimplemented!(stringify!($func)); }

            impl Symbolic for $ty {
                fn symbolic(desc: &'static str) -> $ty { $func(desc) }
            }
        )*
    };
}

uint_impls! {
    u8, symbolic_u8;
    u16, symbolic_u16;
    u32, symbolic_u32;
    u64, symbolic_u64;
    u128, symbolic_u128;
}


macro_rules! usize_impls {
    ($($ty:ty, $width:expr;)*) => {
        $(
            #[cfg(target_pointer_width = $width)]
            impl Symbolic for usize {
                fn symbolic(desc: &'static str) -> usize { <$ty>::symbolic(desc) as usize }
            }
        )*
    };
}

usize_impls! {
    u8, "8";
    u16, "16";
    u32, "32";
    u64, "64";
    u128, "128";
}


macro_rules! int_impls {
    ($($ty:ty, $uty:ty;)*) => {
        $(
            impl Symbolic for $ty {
                fn symbolic(desc: &'static str) -> $ty { <$uty>::symbolic(desc) as $ty }
            }
        )*
    };
}

int_impls! {
    i8, u8;
    i16, u16;
    i32, u32;
    i64, u64;
    i128, u128;
    isize, usize;
}


macro_rules! array_impls {
    ($($size:expr)*) => {
        $(
            impl<T: Symbolic + Copy> Symbolic for [T; $size] {
                fn symbolic(desc: &'static str) -> [T; $size] {
                    let mut arr = [T::symbolic(desc); $size];
                    for i in 1 .. $size {
                        arr[i] = T::symbolic(desc);
                    }
                    arr
                }
            }
        )*
    };
}

array_impls! {
    0 1 2 3 4 5 6 7 8 9
    10 11 12 13 14 15 16 17 18 19
    20 21 22 23 24 25 26 27 28 29
    30 31 32
}


pub fn prefix<'a, T>(xs: &'a [T]) -> &'a [T] {
    let len = usize::symbolic("prefix_len");
    super::crucible_assume!(len <= xs.len());
    &xs[..len]
}
