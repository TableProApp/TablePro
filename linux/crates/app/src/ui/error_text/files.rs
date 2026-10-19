use std::io::ErrorKind;
use std::path::Path;

use tablepro_core::CertificateFileProblem;

use crate::i18n::{gettext, gettext_f, ngettext_f};

/// A database file the file system refused, for a reason other than
/// permission or a missing file, which have their own variants.
pub(super) fn file_io_message(path: &Path, kind: ErrorKind) -> String {
    let path = path.display().to_string();
    let args = [("path", path.as_str())];
    match kind {
        ErrorKind::StorageFull | ErrorKind::QuotaExceeded => {
            gettext_f("Could not write {path}: the disk is full.", &args)
        }
        ErrorKind::ReadOnlyFilesystem => gettext_f("Could not write {path}: the disk is read-only.", &args),
        ErrorKind::FileTooLarge => gettext_f("Could not write {path}: the file is too large.", &args),
        _ => gettext_f("Could not write {path}.", &args),
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
