# 0059: Key errors name the expected signer, and two library limits are written down

- **Status**: Accepted; amends 0056
- **Date**: 2026-11-26

## Context

Gate G1 reviewed `tablepro-keys` against [0056](0056-end-to-end-keys-per-account-and-device.md)'s vectors and passed on round 1. It found five places where 0056 says less than the crate does and has to do:

- the crate returns `keys.random`, which 0056's Errors does not list;
- a signature that fails under the compared DSK or the held IK cannot be told apart from one by another key, and 0056 does not say which code it gets;
- the crate refuses the sign-bit encodings of the two Ed25519 points with x = 0, and 0056 names only y at or above p;
- rustls's HPKE leaves plaintext in heap buffers it does not wipe;
- one negative row gives a server code for an encrypted plaintext, which the server never reads.

0056 is Accepted, so these go in a new ADR, and 0056 changes only its Status line.

## Decision

0056's Errors, Libraries and Vectors read as below. Everything else in 0056 stands.

- **Errors, a new row.** `keys.random`: the system RNG failed, or an HPKE seal failed after the recipient key passed its check, which at these sizes leaves only the RNG.
- **Errors, the expected signer decides the code.**
  - `keys.not_compared`: an `account` or `trust` wrap whose signature does not verify under the DSK this side compared, and a rotation that keeps a device that is not an own-device pin.
  - `keys.unendorsed`: an IK change whose endorsement does not verify under the held IK, or that has none. It opens an alert and fails nothing else.
  - `keys.signature`: the Ed25519 refusals in Libraries, and every other object checked under a signer it names.
- **Libraries, Ed25519 validity.** An encoding of A or R is canonical only when y is below p and, where x is 0, its sign bit is clear. Both sides refuse the sign-bit encodings of the two x = 0 points before the library verifies, and the small-order list covers both sign encodings. Go's `SetBytes` accepts the sign-bit encoding of the identity, so the Go side checks it itself.
- **Libraries, HPKE buffers.** rustls 0.23's `crypto::aws_lc_rs::hpke` leaves three things in heap buffers it does not wipe: the opened plaintext, the sealed plaintext and the labeled DH input. `tablepro-keys` cannot reach them. This is a known gap until rustls wipes those buffers. TablePro sends that change upstream and moves to the rustls release that has it. Reading freed heap needs the device already, which the threat model's stolen-device case covers.
- **Vectors, the encoding row.** The row of non-canonical base64url, wrong lengths, out-of-range versions and malformed members reads `bad_statement` in the Server column for key object bodies and encodings, and none for an encrypted plaintext.

## Consequences

- The crate's codes, the vectors and the Go verifier follow these rows.
- The HPKE plaintext buffers stay unwiped until the rustls change ships.
- 0056's Status names this ADR.
