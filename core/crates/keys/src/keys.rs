use std::fmt;

use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::KeysError;
use crate::crypto;
use crate::encoding::{KeyDeviceId, random_uuid};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Ed25519Public(pub [u8; 32]);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct X25519Public(pub [u8; 32]);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Signature(pub [u8; 64]);

// A scope key's commitment, `kid(K)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Kid(pub [u8; 32]);

impl Ed25519Public {
    pub fn verify(&self, message: &[u8], signature: &Signature) -> Result<(), KeysError> {
        crypto::ed25519_verify(&self.0, message, &signature.0)
    }
}

macro_rules! secret_bytes {
    ($name:ident) => {
        // Zeroized on drop; Debug never prints the bytes.
        #[derive(Clone)]
        pub struct $name(Zeroizing<[u8; 32]>);

        impl $name {
            pub fn from_bytes(bytes: [u8; 32]) -> Self {
                Self(Zeroizing::new(bytes))
            }

            pub fn generate() -> Result<Self, KeysError> {
                let mut bytes = Zeroizing::new([0_u8; 32]);
                crypto::random(bytes.as_mut())?;
                Ok(Self(bytes))
            }

            pub fn expose(&self) -> &[u8; 32] {
                &self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(concat!(stringify!($name), "(redacted)"))
            }
        }

        impl Zeroize for $name {
            fn zeroize(&mut self) {
                self.0.zeroize();
            }
        }

        impl ZeroizeOnDrop for $name {}
    };
}

secret_bytes!(Ed25519Seed);
secret_bytes!(X25519Secret);
secret_bytes!(ScopeKey);

impl Ed25519Seed {
    pub fn public(&self) -> Result<Ed25519Public, KeysError> {
        crypto::ed25519_public(&self.0).map(Ed25519Public)
    }

    pub fn sign(&self, message: &[u8]) -> Result<Signature, KeysError> {
        crypto::ed25519_sign(&self.0, message).map(Signature)
    }
}

impl X25519Secret {
    pub fn public(&self) -> Result<X25519Public, KeysError> {
        crypto::x25519_public(&self.0).map(X25519Public)
    }
}

impl ScopeKey {
    // kid(K) = HKDF-SHA256(salt = none, IKM = K, info = LP("tablepro/v1/key-id") || LP("tp1"), L = 32).
    pub fn kid(&self) -> Result<Kid, KeysError> {
        let info = crate::encoding::Frame::new(crate::encoding::Label::KeyId).finish()?;
        crypto::hkdf32(self.expose(), &info).map(|okm| Kid(*okm))
    }
}

// The account key pair of one `av`: ASK (Ed25519) and AEK (X25519).
#[derive(Clone, Debug)]
pub struct AccountKeys {
    pub ask: Ed25519Seed,
    pub aek: X25519Secret,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AccountPublicKeys {
    pub ask: Ed25519Public,
    pub aek: X25519Public,
}

impl AccountKeys {
    pub fn public(&self) -> Result<AccountPublicKeys, KeysError> {
        Ok(AccountPublicKeys {
            ask: self.ask.public()?,
            aek: self.aek.public()?,
        })
    }

    pub fn generate() -> Result<Self, KeysError> {
        Ok(Self {
            ask: Ed25519Seed::generate()?,
            aek: X25519Secret::generate()?,
        })
    }

    // `ASK seed || AEK private key`, 64 bytes: an `account` wrap's and the recovery blob's plaintext.
    pub fn to_plaintext(&self) -> Zeroizing<[u8; 64]> {
        let mut out = Zeroizing::new([0_u8; 64]);
        out[..32].copy_from_slice(self.ask.expose());
        out[32..].copy_from_slice(self.aek.expose());
        out
    }

    pub fn from_plaintext(plaintext: &[u8]) -> Result<Self, KeysError> {
        if plaintext.len() != 64 {
            return Err(KeysError::encoding("account keys are not 64 bytes"));
        }
        let mut ask = Zeroizing::new([0_u8; 32]);
        let mut aek = Zeroizing::new([0_u8; 32]);
        ask.copy_from_slice(&plaintext[..32]);
        aek.copy_from_slice(&plaintext[32..]);
        Ok(Self {
            ask: Ed25519Seed(ask),
            aek: X25519Secret(aek),
        })
    }

    // The keys give the public keys a certificate names, else keys.mismatch.
    pub fn check_against(&self, ask: &Ed25519Public, aek: &X25519Public) -> Result<(), KeysError> {
        if self.ask.public()? != *ask || self.aek.public()? != *aek {
            return Err(KeysError::Mismatch {
                what: "account keys do not give the certificate's public keys",
            });
        }
        Ok(())
    }
}

impl Zeroize for AccountKeys {
    fn zeroize(&mut self) {
        self.ask.zeroize();
        self.aek.zeroize();
    }
}

impl ZeroizeOnDrop for AccountKeys {}

// A device's own keys: DSK (its DPoP key) and DEK, named by its key device id. Never synced.
#[derive(Clone, Debug)]
pub struct DeviceKeys {
    pub key_device: KeyDeviceId,
    pub dsk: Ed25519Seed,
    pub dek: X25519Secret,
}

impl DeviceKeys {
    // Every approval takes new device keys and a new key device id (ADR 0056, Keys).
    pub fn generate() -> Result<Self, KeysError> {
        Ok(Self {
            key_device: KeyDeviceId(random_uuid()?),
            dsk: Ed25519Seed::generate()?,
            dek: X25519Secret::generate()?,
        })
    }
}

impl Zeroize for DeviceKeys {
    fn zeroize(&mut self) {
        self.dsk.zeroize();
        self.dek.zeroize();
    }
}

impl ZeroizeOnDrop for DeviceKeys {}

#[cfg(test)]
mod tests {
    use zeroize::{Zeroize, ZeroizeOnDrop};

    use super::{AccountKeys, DeviceKeys, Ed25519Seed, ScopeKey, X25519Secret};

    fn zeroized_on_drop<T: ZeroizeOnDrop>() {}

    #[test]
    fn secret_types_zeroize() {
        zeroized_on_drop::<Ed25519Seed>();
        zeroized_on_drop::<X25519Secret>();
        zeroized_on_drop::<ScopeKey>();
        zeroized_on_drop::<AccountKeys>();
        zeroized_on_drop::<DeviceKeys>();

        let mut key = ScopeKey::from_bytes([9; 32]);
        key.zeroize();
        assert_eq!(key.expose(), &[0; 32]);

        let mut keys = AccountKeys {
            ask: Ed25519Seed::from_bytes([1; 32]),
            aek: X25519Secret::from_bytes([2; 32]),
        };
        keys.zeroize();
        assert_eq!(keys.ask.expose(), &[0; 32]);
        assert_eq!(keys.aek.expose(), &[0; 32]);
    }

    #[test]
    fn debug_never_prints_secret_bytes() {
        let key = ScopeKey::from_bytes([0xab; 32]);
        let printed = format!("{key:?}");
        assert_eq!(printed, "ScopeKey(redacted)");
        let keys = AccountKeys {
            ask: Ed25519Seed::from_bytes([0xab; 32]),
            aek: X25519Secret::from_bytes([0xcd; 32]),
        };
        let printed = format!("{keys:?}");
        assert!(!printed.contains("171") && !printed.contains("ab"), "{printed}");
    }

    #[test]
    fn account_keys_round_trip_their_plaintext() {
        let keys = AccountKeys::generate().unwrap();
        let back = AccountKeys::from_plaintext(keys.to_plaintext().as_slice()).unwrap();
        assert_eq!(back.ask.expose(), keys.ask.expose());
        assert_eq!(back.aek.expose(), keys.aek.expose());
        assert!(AccountKeys::from_plaintext(&[0; 63]).is_err());
    }
}
