// Modified from https://github.com/zeta12ti/Checked/blob/master/src/num.rs
// Original license:
// MIT License
//
// Copyright (c) 2017 zeta12ti
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

use std::{cmp::Ordering, convert::TryFrom, fmt, ops::*};

/// The Checked type. See the [module level documentation for more.](index.html)
#[derive(PartialEq, Eq, Clone, Copy, Hash)]
pub struct Checked<T>(pub Option<T>);

impl<T> Checked<T> {
    /// Creates a new Checked instance from some sort of integer.
    #[inline]
    pub fn new(x: T) -> Checked<T> {
        Checked(Some(x))
    }

    pub fn try_from<F>(value: F) -> crate::error::Result<Self>
    where
        T: TryFrom<F>,
        T::Error: std::fmt::Display,
    {
        value
            .try_into()
            .map(|v| Self(Some(v)))
            .map_err(|e| crate::error::Error::invalid_argument(format! {"{e}"}))
    }

    pub fn get(self) -> crate::error::Result<T> {
        self.0
            .ok_or_else(|| crate::error::Error::invalid_argument("checked arithmetic failure"))
    }

    pub fn try_into<F>(self) -> crate::error::Result<F>
    where
        T: TryInto<F>,
        T::Error: std::fmt::Display,
    {
        self.get().and_then(|v| {
            v.try_into()
                .map_err(|e| crate::error::Error::invalid_argument(format!("{e}")))
        })
    }
}

// The derived Default only works if T has Default
// Even though this is what it would be anyway
// May change this to T's default (if it has one)
impl<T> Default for Checked<T> {
    #[inline]
    fn default() -> Checked<T> {
        Checked(None)
    }
}

impl<T: fmt::Debug> fmt::Debug for Checked<T> {
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match **self {
            Some(ref x) => x.fmt(f),
            None => "overflow".fmt(f),
        }
    }
}

impl<T: fmt::Display> fmt::Display for Checked<T> {
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match **self {
            Some(ref x) => x.fmt(f),
            None => "overflow".fmt(f),
        }
    }
}

// I'd like to do
// `impl<T, U> From<U> where T: From<U> for Checked<T>``
// in the obvious way, but that "conflicts" with the default `impl From<T> for T`.
// This would subsume both the below Froms since Option has the right From impl.
impl<T> From<T> for Checked<T> {
    #[inline]
    fn from(x: T) -> Checked<T> {
        Checked(Some(x))
    }
}

impl<T> From<Option<T>> for Checked<T> {
    #[inline]
    fn from(x: Option<T>) -> Checked<T> {
        Checked(x)
    }
}

impl<T> Deref for Checked<T> {
    type Target = Option<T>;

    #[inline]
    fn deref(&self) -> &Option<T> {
        &self.0
    }
}

impl<T> DerefMut for Checked<T> {
    #[inline]
    fn deref_mut(&mut self) -> &mut Option<T> {
        &mut self.0
    }
}

impl<T: PartialOrd> PartialOrd for Checked<T> {
    fn partial_cmp(&self, other: &Checked<T>) -> Option<Ordering> {
        // I'm not really sure why we can't match **self etc. here.
        // Even with refs everywhere it complains
        // Note what happens in this implementation:
        // we take the reference self, and call deref (the method) on it
        // By Deref coercion, self gets derefed to a Checked<T>
        // Now Checked<T>'s deref gets called, returning a &Option<T>
        // That's what gets matched
        match (self.deref(), other.deref()) {
            (Some(x), Some(y)) => PartialOrd::partial_cmp(x, y),
            _ => None,
        }
    }
}

// implements the unary operator `op &T`
// based on `op T` where `T` is expected to be `Copy`able
macro_rules! forward_ref_unop {
    (impl $imp:ident, $method:ident for $t:ty {}) => {
        impl<'a> $imp for &'a $t {
            type Output = <$t as $imp>::Output;

            #[inline]
            fn $method(self) -> <$t as $imp>::Output {
                $imp::$method(*self)
            }
        }
    };
}

// implements binary operators "&T op U", "T op &U", "&T op &U"
// based on "T op U" where T and U are expected to be `Copy`able
macro_rules! forward_ref_binop {
    (impl $imp:ident, $method:ident for $t:ty, $u:ty {}) => {
        impl<'a> $imp<$u> for &'a $t {
            type Output = <$t as $imp<$u>>::Output;

            #[inline]
            fn $method(self, other: $u) -> <$t as $imp<$u>>::Output {
                $imp::$method(*self, other)
            }
        }

        impl<'a> $imp<&'a $u> for $t {
            type Output = <$t as $imp<$u>>::Output;

            #[inline]
            fn $method(self, other: &'a $u) -> <$t as $imp<$u>>::Output {
                $imp::$method(self, *other)
            }
        }

        impl<'a, 'b> $imp<&'a $u> for &'b $t {
            type Output = <$t as $imp<$u>>::Output;

            #[inline]
            fn $method(self, other: &'a $u) -> <$t as $imp<$u>>::Output {
                $imp::$method(*self, *other)
            }
        }
    };
}

macro_rules! impl_sh {
    ($t:ident, $f:ident) => {
        impl Shl<Checked<$f>> for Checked<$t> {
            type Output = Checked<$t>;

            fn shl(self, other: Checked<$f>) -> Checked<$t> {
                match (*self, *other) {
                    (Some(x), Some(y)) => Checked(x.checked_shl(y)),
                    _ => Checked(None),
                }
            }
        }

        impl Shl<$f> for Checked<$t> {
            type Output = Checked<$t>;

            fn shl(self, other: $f) -> Checked<$t> {
                match *self {
                    Some(x) => Checked(x.checked_shl(other)),
                    None => Checked(None),
                }
            }
        }

        forward_ref_binop! { impl Shl, shl for Checked<$t>, Checked<$f> {} }
        forward_ref_binop! { impl Shl, shl for Checked<$t>, $f {} }

        impl ShlAssign<$f> for Checked<$t> {
            #[inline]
            fn shl_assign(&mut self, other: $f) {
                *self = *self << other;
            }
        }

        impl ShlAssign<Checked<$f>> for Checked<$t> {
            #[inline]
            fn shl_assign(&mut self, other: Checked<$f>) {
                *self = *self << other;
            }
        }

        impl Shr<Checked<$f>> for Checked<$t> {
            type Output = Checked<$t>;

            fn shr(self, other: Checked<$f>) -> Checked<$t> {
                match (*self, *other) {
                    (Some(x), Some(y)) => Checked(x.checked_shr(y)),
                    _ => Checked(None),
                }
            }
        }

        impl Shr<$f> for Checked<$t> {
            type Output = Checked<$t>;

            fn shr(self, other: $f) -> Checked<$t> {
                match *self {
                    Some(x) => Checked(x.checked_shr(other)),
                    None => Checked(None),
                }
            }
        }

        forward_ref_binop! { impl Shr, shr for Checked<$t>, Checked<$f> {} }
        forward_ref_binop! { impl Shr, shr for Checked<$t>, $f {} }

        impl ShrAssign<$f> for Checked<$t> {
            #[inline]
            fn shr_assign(&mut self, other: $f) {
                *self = *self >> other;
            }
        }

        impl ShrAssign<Checked<$f>> for Checked<$t> {
            #[inline]
            fn shr_assign(&mut self, other: Checked<$f>) {
                *self = *self >> other;
            }
        }
    };
}

macro_rules! impl_sh_reverse {
    ($t:ident, $f:ident) => {
        impl Shl<Checked<$t>> for $f {
            type Output = Checked<$f>;

            fn shl(self, other: Checked<$t>) -> Checked<$f> {
                match *other {
                    Some(x) => Checked(self.checked_shl(x)),
                    None => Checked(None),
                }
            }
        }

        forward_ref_binop! { impl Shl, shl for $f, Checked<$t> {} }

        impl Shr<Checked<$t>> for $f {
            type Output = Checked<$f>;

            fn shr(self, other: Checked<$t>) -> Checked<$f> {
                match *other {
                    Some(x) => Checked(self.checked_shr(x)),
                    None => Checked(None),
                }
            }
        }

        forward_ref_binop! { impl Shr, shr for $f, Checked<$t> {} }
    };
}

macro_rules! impl_sh_all {
    ($($t:ident)*) => ($(
        // When checked_shX is added for other shift sizes, uncomment some of these.
        // impl_sh! { $t, u8 }
        // impl_sh! { $t, u16 }
        impl_sh! { $t, u32 }
        //impl_sh! { $t, u64 }
        //impl_sh! { $t, usize }

        //impl_sh! { $t, i8 }
        //impl_sh! { $t, i16 }
        //impl_sh! { $t, i32 }
        //impl_sh! { $t, i64 }
        //impl_sh! { $t, isize }

        // impl_sh_reverse! { u8, $t }
        // impl_sh_reverse! { u16, $t }
        impl_sh_reverse! { u32, $t }
        //impl_sh_reverse! { u64, $t }
        //impl_sh_reverse! { usize, $t }

        //impl_sh_reverse! { i8, $t }
        //impl_sh_reverse! { i16, $t }
        //impl_sh_reverse! { i32, $t }
        //impl_sh_reverse! { i64, $t }
        //impl_sh_reverse! { isize, $t }
    )*)
}

impl_sh_all! { u8 u16 u32 u64 usize i8 i16 i32 i64 isize }

// implements unary operators for checked types
macro_rules! impl_unop {
    (impl $imp:ident, $method:ident, $checked_method:ident for $t:ty {}) => {
        impl $imp for Checked<$t> {
            type Output = Checked<$t>;

            fn $method(self) -> Checked<$t> {
                match *self {
                    Some(x) => Checked(x.$checked_method()),
                    None => Checked(None),
                }
            }
        }

        forward_ref_unop! { impl $imp, $method for Checked<$t> {} }
    };
}

// implements unary operators for checked types (with no checked method)
macro_rules! impl_unop_unchecked {
    (impl $imp:ident, $method:ident for $t:ty {$op:tt}) => {
        impl $imp for Checked<$t> {
            type Output = Checked<$t>;

            fn $method(self) -> Checked<$t> {
                match *self {
                    Some(x) => Checked(Some($op x)),
                    None => Checked(None)
                }
            }
        }

        forward_ref_unop! { impl $imp, $method for Checked<$t> {} }
    }
}

// implements binary operators for checked types
macro_rules! impl_binop {
    (impl $imp:ident, $method:ident, $checked_method:ident for $t:ty {}) => {
        impl $imp for Checked<$t> {
            type Output = Checked<$t>;

            fn $method(self, other: Checked<$t>) -> Checked<$t> {
                match (*self, *other) {
                    (Some(x), Some(y)) => Checked(x.$checked_method(y)),
                    _ => Checked(None),
                }
            }
        }

        impl $imp<$t> for Checked<$t> {
            type Output = Checked<$t>;

            fn $method(self, other: $t) -> Checked<$t> {
                match *self {
                    Some(x) => Checked(x.$checked_method(other)),
                    _ => Checked(None),
                }
            }
        }

        impl $imp<Checked<$t>> for $t {
            type Output = Checked<$t>;

            fn $method(self, other: Checked<$t>) -> Checked<$t> {
                match *other {
                    Some(x) => Checked(self.$checked_method(x)),
                    None => Checked(None),
                }
            }
        }

        forward_ref_binop! { impl $imp, $method for Checked<$t>, Checked<$t> {} }
        forward_ref_binop! { impl $imp, $method for Checked<$t>, $t {} }
        forward_ref_binop! { impl $imp, $method for $t, Checked<$t> {} }
    };
}

// implements binary operators for checked types (no checked method)
macro_rules! impl_binop_unchecked {
    (impl $imp:ident, $method:ident for $t:ty {$op:tt}) => {
        impl $imp for Checked<$t> {
            type Output = Checked<$t>;

            fn $method(self, other: Checked<$t>) -> Checked<$t> {
                match (*self, *other) {
                    (Some(x), Some(y)) => Checked(Some(x $op y)),
                    _ => Checked(None),
                }
            }
        }

        impl $imp<$t> for Checked<$t> {
            type Output = Checked<$t>;

            fn $method(self, other: $t) -> Checked<$t> {
                match *self {
                    Some(x) => Checked(Some(x $op other)),
                    _ => Checked(None),
                }
            }
        }

        impl $imp<Checked<$t>> for $t {
            type Output = Checked<$t>;

            fn $method(self, other: Checked<$t>) -> Checked<$t> {
                match *other {
                    Some(x) => Checked(Some(self $op x)),
                    None => Checked(None),
                }
            }
        }

        forward_ref_binop! { impl $imp, $method for Checked<$t>, Checked<$t> {} }
        forward_ref_binop! { impl $imp, $method for Checked<$t>, $t {} }
        forward_ref_binop! { impl $imp, $method for $t, Checked<$t> {} }
    }
}

// implements assignment operators for checked types
macro_rules! impl_binop_assign {
    (impl $imp:ident, $method:ident for $t:ty {$op:tt}) => {
        impl $imp for Checked<$t> {
            #[inline]
            fn $method(&mut self, other: Checked<$t>) {
                *self = *self $op other;
            }
        }

        impl $imp<$t> for Checked<$t> {
            #[inline]
            fn $method(&mut self, other: $t) {
                *self = *self $op other;
            }
        }
    };
}

macro_rules! checked_impl {
    ($($t:ty)*) => {
        $(
            impl_binop! { impl Add, add, checked_add for $t {} }
            impl_binop_assign! { impl AddAssign, add_assign for $t {+} }
            impl_binop! { impl Sub, sub, checked_sub for $t {} }
            impl_binop_assign! { impl SubAssign, sub_assign for $t {-} }
            impl_binop! { impl Mul, mul, checked_mul for $t {} }
            impl_binop_assign! { impl MulAssign, mul_assign for $t {*} }
            impl_binop! { impl Div, div, checked_div for $t {} }
            impl_binop_assign! { impl DivAssign, div_assign for $t {/} }
            impl_binop! { impl Rem, rem, checked_rem for $t {} }
            impl_binop_assign! { impl RemAssign, rem_assign for $t {%} }
            impl_unop_unchecked! { impl Not, not for $t {!} }
            impl_binop_unchecked! { impl BitXor, bitxor for $t {^} }
            impl_binop_assign! { impl BitXorAssign, bitxor_assign for $t {^} }
            impl_binop_unchecked! { impl BitOr, bitor for $t {|} }
            impl_binop_assign! { impl BitOrAssign, bitor_assign for $t {|} }
            impl_binop_unchecked! { impl BitAnd, bitand for $t {&} }
            impl_binop_assign! { impl BitAndAssign, bitand_assign for $t {&} }
            impl_unop! { impl Neg, neg, checked_neg for $t {} }

        )*
    };
}

checked_impl! { u8 u16 u32 u64 usize i8 i16 i32 i64 isize }
