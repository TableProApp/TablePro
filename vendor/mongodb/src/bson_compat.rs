#[cfg(feature = "bson-3")]
pub(crate) type CStr = crate::bson::raw::CStr;
#[cfg(feature = "bson-3")]
pub(crate) type CString = crate::bson::raw::CString;
#[cfg(feature = "bson-3")]
pub(crate) use crate::bson::raw::cstr;

#[cfg(not(feature = "bson-3"))]
pub(crate) type CStr = str;
#[cfg(not(feature = "bson-3"))]
pub(crate) type CString = String;
#[cfg(not(feature = "bson-3"))]
macro_rules! cstr {
    ($text:literal) => {
        $text
    };
}
#[cfg(not(feature = "bson-3"))]
pub(crate) use cstr;

pub(crate) fn cstr_to_str(cs: &CStr) -> &str {
    #[cfg(feature = "bson-3")]
    {
        cs.as_str()
    }
    #[cfg(not(feature = "bson-3"))]
    {
        cs
    }
}

pub(crate) fn str_to_cstr(s: &str) -> crate::error::Result<&CStr> {
    #[cfg(feature = "bson-3")]
    {
        Ok(s.try_into()?)
    }
    #[cfg(not(feature = "bson-3"))]
    {
        Ok(s)
    }
}

#[cfg(feature = "bson-3")]
pub(crate) trait RawDocumentBufExt: Sized {
    fn append_ref<'a>(
        &mut self,
        key: impl AsRef<CStr>,
        value: impl Into<crate::bson::raw::RawBsonRef<'a>> + 'a,
    );

    #[allow(unused)]
    fn to_document(&self) -> crate::error::Result<crate::bson::Document>;
}

#[cfg(feature = "bson-3")]
impl RawDocumentBufExt for crate::bson::RawDocumentBuf {
    fn append_ref<'a>(
        &mut self,
        key: impl AsRef<CStr>,
        value: impl Into<crate::bson::raw::RawBsonRef<'a>> + 'a,
    ) {
        self.append(key, value);
    }

    fn to_document(&self) -> crate::error::Result<crate::bson::Document> {
        self.try_into().map_err(Into::into)
    }
}

#[cfg(feature = "bson-3")]
pub(crate) trait RawBsonRefExt {
    fn to_raw_bson(&self) -> crate::bson::RawBson;
}

#[cfg(feature = "bson-3")]
impl RawBsonRefExt for crate::bson::RawBsonRef<'_> {
    fn to_raw_bson(&self) -> crate::bson::RawBson {
        (*self).into()
    }
}

macro_rules! use_either {
    ($($name:ident => $path3:path | $path2:path);+;) => {
        $(
            #[cfg(feature = "bson-3")]
            #[allow(unused_imports)]
            pub(crate) use crate::bson::{$path3 as $name};

            #[cfg(not(feature = "bson-3"))]
            #[allow(unused_imports)]
            pub(crate) use crate::bson::{$path2 as $name};
        )+
    };
}

// Exported name => bson3 import | bson2 import
use_either! {
    RawResult                       => error::Result                    | raw::Result;
    RawError                        => error::Error                     | raw::Error;
    DeError                         => error::Error                     | de::Error;
    SerError                        => error::Error                     | ser::Error;
    Utf8Lossy                       => Utf8Lossy                        | serde_helpers::Utf8LossyDeserialization;
    serialize_to_raw_document_buf   => serialize_to_raw_document_buf    | to_raw_document_buf;
    serialize_to_document           => serialize_to_document            | to_document;
    serialize_to_bson               => serialize_to_bson                | to_bson;
    deserialize_from_slice          => deserialize_from_slice           | from_slice;
    deserialize_from_document       => deserialize_from_document        | from_document;
    deserialize_from_bson           => deserialize_from_bson            | from_bson;
}
