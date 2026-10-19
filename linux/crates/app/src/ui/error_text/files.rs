use std::io::ErrorKind;
use std::path::Path;

use gtk4::glib;
use tablepro_core::CertificateFileProblem;
use tablepro_storage::StorageError;

use crate::i18n::{gettext, gettext_f, ngettext_f};

/// A file the file system refused to write. The error's own text is
/// std's or GLib's, so only its kind is used.
pub(super) fn file_io_message(path: &Path, kind: ErrorKind) -> String {
    let path = path.display().to_string();
    let args = [("path", path.as_str())];
    match kind {
        ErrorKind::StorageFull | ErrorKind::QuotaExceeded => {
            gettext_f("Could not write {path}: the disk is full.", &args)
        }
        ErrorKind::ReadOnlyFilesystem => gettext_f("Could not write {path}: the disk is read-only.", &args),
        ErrorKind::FileTooLarge => gettext_f("Could not write {path}: the file is too large.", &args),
        ErrorKind::PermissionDenied => gettext_f("TablePro is not allowed to write {path}.", &args),
        _ => gettext_f("Could not write {path}.", &args),
    }
}

/// Why one of the app's own files could not be written, or `None` when
/// the failure was not the file system's.
pub fn storage_io_message(error: &StorageError) -> Option<String> {
    match error {
        StorageError::Io { path, source } | StorageError::Permissions { path, source } => {
            Some(file_io_message(path, source.kind()))
        }
        StorageError::Write { path, source } => Some(file_io_message(path, glib_file_error_kind(source))),
        _ => None,
    }
}

fn glib_file_error_kind(error: &glib::Error) -> ErrorKind {
    match error.kind::<glib::FileError>() {
        Some(glib::FileError::Nospc) => ErrorKind::StorageFull,
        Some(glib::FileError::Rofs) => ErrorKind::ReadOnlyFilesystem,
        Some(glib::FileError::Acces | glib::FileError::Perm) => ErrorKind::PermissionDenied,
        _ => ErrorKind::Other,
    }
}

/// What is wrong with a CA, certificate or key file, as the part after
/// "cannot be used:".
pub(super) fn certificate_problem_text(problem: &CertificateFileProblem) -> String {
    match problem {
        CertificateFileProblem::Unreadable {
            kind: ErrorKind::NotFound,
        } => gettext("the file does not exist"),
        CertificateFileProblem::Unreadable {
            kind: ErrorKind::PermissionDenied,
        } => gettext("TablePro is not allowed to read it"),
        CertificateFileProblem::Unreadable { .. } => gettext("the file could not be read"),
        CertificateFileProblem::NotRegularFile => gettext("it is not a plain file"),
        CertificateFileProblem::TooLarge { limit_bytes } => {
            gettext_f("it is larger than {size}", &[("size", &size_text(*limit_bytes))])
        }
        CertificateFileProblem::NoCertificates => gettext("it holds no certificates"),
        CertificateFileProblem::InvalidCertificate => gettext("a certificate in it is not valid"),
        CertificateFileProblem::MultipleCertificates { count } => ngettext_f(
            "it holds {count} certificate, and only one is allowed",
            "it holds {count} certificates, and only one is allowed",
            u32::try_from(*count).unwrap_or(u32::MAX),
            &[("count", &count.to_string())],
        ),
        CertificateFileProblem::NoPrivateKey => gettext("it holds no private key"),
        CertificateFileProblem::InvalidPrivateKey => gettext("its private key is not valid"),
    }
}

fn size_text(bytes: usize) -> String {
    gtk4::glib::format_size(u64::try_from(bytes).unwrap_or(u64::MAX)).to_string()
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn a_refused_write_names_the_file_and_the_reason_in_the_apps_words() {
        let path = Path::new("/srv/app.db");

        let full = file_io_message(path, ErrorKind::StorageFull);
        let read_only = file_io_message(path, ErrorKind::ReadOnlyFilesystem);
        let other = file_io_message(path, ErrorKind::Interrupted);

        assert_eq!(full, "Could not write /srv/app.db: the disk is full.");
        assert_eq!(read_only, "Could not write /srv/app.db: the disk is read-only.");
        assert_eq!(other, "Could not write /srv/app.db.");
        assert!(!full.contains(&ErrorKind::StorageFull.to_string()), "{full}");
    }

    #[test]
    fn a_refused_write_of_the_apps_own_file_is_worded_by_its_kind() {
        let path = PathBuf::from("/home/ada/.local/share/tablepro/connections.json");
        let io = |kind: ErrorKind| StorageError::Io {
            path: path.clone(),
            source: std::io::Error::from(kind),
        };
        let glib_write = |code: glib::FileError| StorageError::Write {
            path: path.clone(),
            source: glib::Error::new(code, "Failed to create file: No space left on device"),
        };
        let cases = [
            (io(ErrorKind::StorageFull), "Could not write {path}: the disk is full."),
            (
                io(ErrorKind::PermissionDenied),
                "TablePro is not allowed to write {path}.",
            ),
            (io(ErrorKind::Interrupted), "Could not write {path}."),
            (
                glib_write(glib::FileError::Nospc),
                "Could not write {path}: the disk is full.",
            ),
            (
                glib_write(glib::FileError::Rofs),
                "Could not write {path}: the disk is read-only.",
            ),
            (
                glib_write(glib::FileError::Acces),
                "TablePro is not allowed to write {path}.",
            ),
            (glib_write(glib::FileError::Io), "Could not write {path}."),
        ];

        for (error, expected) in cases {
            let expected = expected.replace("{path}", &path.display().to_string());
            assert_eq!(
                storage_io_message(&error).as_deref(),
                Some(expected.as_str()),
                "{error:?}"
            );
        }
        assert_eq!(
            storage_io_message(&StorageError::Schema("the disk is full".to_owned())),
            None
        );
    }

    #[test]
    fn every_certificate_problem_has_its_own_words() {
        let problems = [
            CertificateFileProblem::Unreadable {
                kind: ErrorKind::NotFound,
            },
            CertificateFileProblem::Unreadable {
                kind: ErrorKind::PermissionDenied,
            },
            CertificateFileProblem::Unreadable {
                kind: ErrorKind::Interrupted,
            },
            CertificateFileProblem::NotRegularFile,
            CertificateFileProblem::TooLarge {
                limit_bytes: 1024 * 1024,
            },
            CertificateFileProblem::NoCertificates,
            CertificateFileProblem::InvalidCertificate,
            CertificateFileProblem::MultipleCertificates { count: 2 },
            CertificateFileProblem::NoPrivateKey,
            CertificateFileProblem::InvalidPrivateKey,
        ];

        let texts: Vec<String> = problems.iter().map(certificate_problem_text).collect();

        for (problem, text) in problems.iter().zip(&texts) {
            assert_ne!(text, &problem.to_string(), "{problem:?} shows its log text");
        }
        assert_eq!(texts.iter().collect::<HashSet<_>>().len(), problems.len(), "{texts:?}");
        assert_eq!(
            texts[4],
            format!("it is larger than {}", gtk4::glib::format_size(1024 * 1024))
        );
        assert_eq!(texts[7], "it holds 2 certificates, and only one is allowed");
    }
}
