

fn call_with_one(some_closure: &Fn(i32) -> i32) -> i32 {

    some_closure(1)

}

fn f (y:i32) -> i32 {

    call_with_one(&|x| x + y)

}

const ARG :i32 = 2;

#[cfg(with_main)]
fn main() {
    println!("{:?}", f(ARG))
}