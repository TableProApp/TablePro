use tokio::io::{AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::error::{ErrorKind, Result};

/// The wire protocol op codes.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub(crate) enum OpCode {
    Reply = 1,
    Query = 2004,
    Message = 2013,
    Compressed = 2012,
}

impl OpCode {
    /// Attempt to infer the op code based on the numeric value.
    fn from_i32(i: i32) -> Result<Self> {
        match i {
            1 => Ok(OpCode::Reply),
            2004 => Ok(OpCode::Query),
            2013 => Ok(OpCode::Message),
            2012 => Ok(OpCode::Compressed),
            other => Err(ErrorKind::InvalidResponse {
                message: format!("Invalid wire protocol opcode: {other}"),
            }
            .into()),
        }
    }
}

/// The header for any wire protocol message.
#[derive(Debug)]
pub(crate) struct Header {
    pub length: i32,
    pub request_id: i32,
    pub response_to: i32,
    pub op_code: OpCode,
}

impl Header {
    pub(crate) const LENGTH: usize = 4 * std::mem::size_of::<i32>();

    /// Serializes the Header and writes the bytes to `w`.
    pub(crate) async fn write_to<W: AsyncWrite + Unpin>(&self, stream: &mut W) -> Result<()> {
        stream.write_all(&self.length.to_le_bytes()).await?;
        stream.write_all(&self.request_id.to_le_bytes()).await?;
        stream.write_all(&self.response_to.to_le_bytes()).await?;
        stream
            .write_all(&(self.op_code as i32).to_le_bytes())
            .await?;

        Ok(())
    }

    /// Reads bytes from `r` and deserializes them into a header.
    pub(crate) async fn read_from<R: tokio::io::AsyncRead + Unpin + Send>(
        reader: &mut R,
    ) -> Result<Self> {
        let length = reader.read_i32_le().await?;
        let request_id = reader.read_i32_le().await?;
        let response_to = reader.read_i32_le().await?;
        let op_code = OpCode::from_i32(reader.read_i32_le().await?)?;
        Ok(Self {
            length,
            request_id,
            response_to,
            op_code,
        })
    }
}
