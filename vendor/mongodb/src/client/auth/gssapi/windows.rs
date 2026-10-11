use std::ptr;
use windows_sys::Win32::{
    Foundation::{SEC_E_OK, SEC_I_CONTINUE_NEEDED},
    Security::{
        Authentication::Identity::{
            AcquireCredentialsHandleW,
            DecryptMessage,
            DeleteSecurityContext,
            EncryptMessage,
            FreeCredentialsHandle,
            InitializeSecurityContextW,
            QueryContextAttributesW,
            SecBuffer,
            SecBufferDesc,
            SecPkgContext_Sizes,
            ISC_REQ_ALLOCATE_MEMORY,
            ISC_REQ_MUTUAL_AUTH,
            SECBUFFER_DATA,
            SECBUFFER_PADDING,
            SECBUFFER_STREAM,
            SECBUFFER_TOKEN,
            SECBUFFER_VERSION,
            SECPKG_ATTR_SIZES,
            SECPKG_CRED_OUTBOUND,
            SECQOP_WRAP_NO_ENCRYPT,
            SECURITY_NETWORK_DREP,
        },
        Credentials::SecHandle,
    },
    System::Rpc::{SEC_WINNT_AUTH_IDENTITY_UNICODE, SEC_WINNT_AUTH_IDENTITY_W},
};

use crate::{
    client::auth::GSSAPI_STR,
    error::{Error, Result},
};

pub(super) struct SspiAuthenticator {
    cred_handle: Option<SecHandle>,
    ctx_handle: Option<SecHandle>,
    auth_complete: bool,
    service_principal: Vec<u16>,
    user_principal: String,
}

impl SspiAuthenticator {
    // Initialize the SspiAuthenticator by acquiring a credentials handle and
    // making the first call to InitializeSecurityContext.
    pub(super) fn init(
        user_principal: Option<String>,
        password: Option<String>,
        service_principal: String,
    ) -> Result<(Self, Vec<u8>)> {
        let user_principal = user_principal.ok_or_else(|| {
            Error::authentication_error(GSSAPI_STR, "User principal not specified")
        })?;

        let service_principal: Vec<u16> = service_principal
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();

        let mut authenticator = Self {
            cred_handle: None,
            ctx_handle: None,
            auth_complete: false,
            service_principal,
            user_principal: user_principal.clone(),
        };

        let initial_token = authenticator.acquire_credentials_and_init(password)?;
        Ok((authenticator, initial_token))
    }

    fn acquire_credentials_and_init(&mut self, password: Option<String>) -> Result<Vec<u8>> {
        let mut cred_handle = SecHandle::default();
        let mut expiry: i64 = 0;

        let mut auth_identity = SEC_WINNT_AUTH_IDENTITY_W::default();
        auth_identity.Flags = SEC_WINNT_AUTH_IDENTITY_UNICODE;

        // Note that SSPI uses the term "domain" instead of
        // "realm" in this context.
        let username_wide: Vec<u16>;
        let domain_wide: Vec<u16>;
        let password_wide: Vec<u16>;

        if let Some(at_pos) = self.user_principal.find('@') {
            let username = &self.user_principal[..at_pos];
            let domain = &self.user_principal[at_pos + 1..];

            username_wide = username.encode_utf16().chain(std::iter::once(0)).collect();
            domain_wide = domain.encode_utf16().chain(std::iter::once(0)).collect();

            auth_identity.User = username_wide.as_ptr() as *mut u16;
            auth_identity.UserLength = username.len() as u32;
            auth_identity.Domain = domain_wide.as_ptr() as *mut u16;
            auth_identity.DomainLength = domain.len() as u32;

            if let Some(password) = &password {
                password_wide = password.encode_utf16().chain(std::iter::once(0)).collect();
                auth_identity.Password = password_wide.as_ptr() as *mut u16;
                auth_identity.PasswordLength = password.len() as u32;
            }
        }

        // Security package name
        let package_name: Vec<u16> = "kerberos\0".encode_utf16().collect();

        // nosemgrep: rust.lang.security.unsafe-usage.unsafe-usage
        unsafe {
            let result = AcquireCredentialsHandleW(
                std::ptr::null(),
                package_name.as_ptr(),
                SECPKG_CRED_OUTBOUND,
                ptr::null_mut(),
                if password.is_some() {
                    // Only pass credentials if a password is present. See DRIVERS-2180.
                    &auth_identity as *const _ as *const _
                } else {
                    ptr::null()
                },
                None,
                ptr::null_mut(),
                &mut cred_handle,
                &mut expiry,
            );

            if result != SEC_E_OK {
                return Err(Error::authentication_error(
                    GSSAPI_STR,
                    &format!("Failed to acquire credentials handle: {:?}", result),
                ));
            }
        }

        self.cred_handle = Some(cred_handle);

        let initial_token = self.initialize_security_context(&[])?;
        Ok(initial_token)
    }

    // Issue the server provided token to the context handle. If auth is complete,
    // no token is returned; otherwise, return the next token to send to the server.
    pub(super) fn step(&mut self, challenge: &[u8]) -> Result<Option<Vec<u8>>> {
        if self.auth_complete {
            return Ok(None);
        }

        let token = self.initialize_security_context(challenge)?;
        Ok(Some(token))
    }

    fn initialize_security_context(&mut self, input_token: &[u8]) -> Result<Vec<u8>> {
        let mut ctx_handle = self.ctx_handle.unwrap_or_default();

        let mut input_buffer = SecBuffer {
            cbBuffer: input_token.len() as u32,
            BufferType: SECBUFFER_TOKEN,
            pvBuffer: if input_token.is_empty() {
                ptr::null_mut()
            } else {
                input_token.as_ptr() as *mut _
            },
        };

        let input_buffer_desc = SecBufferDesc {
            ulVersion: SECBUFFER_VERSION,
            cBuffers: 1,
            pBuffers: &mut input_buffer,
        };

        let mut output_buffer = SecBuffer {
            cbBuffer: 0,
            BufferType: SECBUFFER_TOKEN,
            pvBuffer: ptr::null_mut(),
        };

        let mut output_buffer_desc = SecBufferDesc {
            ulVersion: SECBUFFER_VERSION,
            cBuffers: 1,
            pBuffers: &mut output_buffer,
        };

        let mut context_attr = 0u32;

        // nosemgrep: rust.lang.security.unsafe-usage.unsafe-usage
        unsafe {
            let result = InitializeSecurityContextW(
                &self.cred_handle.unwrap(),
                if self.ctx_handle.is_some() {
                    &ctx_handle
                } else {
                    ptr::null()
                },
                self.service_principal.as_ptr(),
                ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_MUTUAL_AUTH,
                0,
                SECURITY_NETWORK_DREP,
                if self.ctx_handle.is_some() {
                    &input_buffer_desc
                } else {
                    ptr::null()
                },
                0,
                &mut ctx_handle,
                &mut output_buffer_desc,
                &mut context_attr,
                ptr::null_mut(),
            );

            self.ctx_handle = Some(ctx_handle);

            match result {
                SEC_E_OK => {
                    self.auth_complete = true;
                }
                SEC_I_CONTINUE_NEEDED => {}
                _ => {
                    return Err(Error::authentication_error(
                        GSSAPI_STR,
                        &format!("InitializeSecurityContext failed: {:?}", result),
                    ));
                }
            }

            let token = if output_buffer.pvBuffer.is_null() || output_buffer.cbBuffer == 0 {
                Vec::new()
            } else {
                let token_slice = std::slice::from_raw_parts(
                    output_buffer.pvBuffer as *const u8,
                    output_buffer.cbBuffer as usize,
                );
                token_slice.to_vec()
            };

            Ok(token)
        }
    }

    // Perform the final step of Kerberos authentication by decrypting the
    // final server challenge, then encrypting the protocol bytes + user
    // principal. The resulting token must be sent to the server.
    // For consistency with nix/GSSAPI, we use the terminology "unwrap" and
    // "wrap" here, even though in the context of SSPI it is "decrypt" and
    // "encrypt" (as seen in the implementation of this method).
    pub(super) fn do_unwrap_wrap(&mut self, payload: &[u8]) -> Result<Vec<u8>> {
        let mut message = payload.to_vec();

        let mut wrap_bufs = [
            SecBuffer {
                cbBuffer: message.len() as u32,
                BufferType: SECBUFFER_STREAM,
                pvBuffer: message.as_mut_ptr() as *mut _,
            },
            SecBuffer {
                cbBuffer: 0,
                BufferType: SECBUFFER_DATA,
                pvBuffer: ptr::null_mut(),
            },
        ];

        let mut wrap_buf_desc = SecBufferDesc {
            ulVersion: SECBUFFER_VERSION,
            cBuffers: 2,
            pBuffers: wrap_bufs.as_mut_ptr(),
        };

        // nosemgrep: rust.lang.security.unsafe-usage.unsafe-usage
        unsafe {
            let result = DecryptMessage(
                &self.ctx_handle.unwrap(),
                &mut wrap_buf_desc,
                0,
                ptr::null_mut(),
            );
            if result != SEC_E_OK {
                return Err(Error::authentication_error(
                    GSSAPI_STR,
                    &format!("DecryptMessage failed: {:?}", result),
                ));
            }
        }

        if wrap_bufs[1].cbBuffer < 4 {
            return Err(Error::authentication_error(
                GSSAPI_STR,
                "Server message is too short",
            ));
        }

        let mut sizes = SecPkgContext_Sizes::default();

        // nosemgrep: rust.lang.security.unsafe-usage.unsafe-usage
        unsafe {
            let result = QueryContextAttributesW(
                &self.ctx_handle.unwrap(),
                SECPKG_ATTR_SIZES,
                &mut sizes as *mut _ as *mut _,
            );
            if result != SEC_E_OK {
                return Err(Error::authentication_error(
                    GSSAPI_STR,
                    &format!("QueryContextAttributes failed: {:?}", result),
                ));
            }
        }

        let user_principal = &self.user_principal;
        let plaintext_message_size = 4 + user_principal.len();
        let total_size =
            sizes.cbSecurityTrailer as usize + plaintext_message_size + sizes.cbBlockSize as usize;
        let mut message_buf = vec![0u8; total_size];

        let plaintext_start = sizes.cbSecurityTrailer as usize;
        message_buf[plaintext_start] = 1;
        message_buf[plaintext_start + 1] = 0;
        message_buf[plaintext_start + 2] = 0;
        message_buf[plaintext_start + 3] = 0;
        message_buf[plaintext_start + 4..plaintext_start + 4 + user_principal.len()]
            .copy_from_slice(user_principal.as_bytes());

        // nosemgrep: rust.lang.security.unsafe-usage.unsafe-usage
        unsafe {
            let mut encrypt_bufs = [
                SecBuffer {
                    cbBuffer: sizes.cbSecurityTrailer,
                    BufferType: SECBUFFER_TOKEN,
                    pvBuffer: message_buf.as_mut_ptr() as *mut _,
                },
                SecBuffer {
                    cbBuffer: plaintext_message_size as u32,
                    BufferType: SECBUFFER_DATA,
                    pvBuffer: message_buf
                        .as_mut_ptr()
                        .add(sizes.cbSecurityTrailer as usize)
                        as *mut _,
                },
                SecBuffer {
                    cbBuffer: sizes.cbBlockSize,
                    BufferType: SECBUFFER_PADDING,
                    pvBuffer: message_buf
                        .as_mut_ptr()
                        .add(plaintext_start + plaintext_message_size)
                        as *mut _,
                },
            ];

            let mut encrypt_buf_desc = SecBufferDesc {
                ulVersion: SECBUFFER_VERSION,
                cBuffers: 3,
                pBuffers: encrypt_bufs.as_mut_ptr(),
            };

            let result = EncryptMessage(
                &self.ctx_handle.unwrap(),
                SECQOP_WRAP_NO_ENCRYPT,
                &mut encrypt_buf_desc,
                0,
            );
            if result != SEC_E_OK {
                return Err(Error::authentication_error(
                    GSSAPI_STR,
                    &format!("EncryptMessage failed: {:?}", result),
                ));
            }

            let total_len =
                encrypt_bufs[0].cbBuffer + encrypt_bufs[1].cbBuffer + encrypt_bufs[2].cbBuffer;
            let mut result_buf = Vec::with_capacity(total_len as usize);

            let buf0_slice = std::slice::from_raw_parts(
                encrypt_bufs[0].pvBuffer as *const u8,
                encrypt_bufs[0].cbBuffer as usize,
            );
            result_buf.extend_from_slice(buf0_slice);

            let buf1_slice = std::slice::from_raw_parts(
                encrypt_bufs[1].pvBuffer as *const u8,
                encrypt_bufs[1].cbBuffer as usize,
            );
            result_buf.extend_from_slice(buf1_slice);

            let buf2_slice = std::slice::from_raw_parts(
                encrypt_bufs[2].pvBuffer as *const u8,
                encrypt_bufs[2].cbBuffer as usize,
            );
            result_buf.extend_from_slice(buf2_slice);

            Ok(result_buf)
        }
    }

    pub(super) fn is_complete(&self) -> bool {
        self.auth_complete
    }
}

impl Drop for SspiAuthenticator {
    fn drop(&mut self) {
        // nosemgrep: rust.lang.security.unsafe-usage.unsafe-usage
        unsafe {
            if let Some(ctx) = &self.ctx_handle {
                let _ = DeleteSecurityContext(ctx);
            }
            if let Some(cred) = &self.cred_handle {
                let _ = FreeCredentialsHandle(cred);
            }
        }
    }
}
