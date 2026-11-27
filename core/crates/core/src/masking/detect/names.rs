use crate::masking::MaskingStyle;

// A term as the words of a name spell it once joined. `single_word` terms match only one whole word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Term {
    pub compact: &'static str,
    pub single_word: bool,
    pub style: MaskingStyle,
}

const fn term(compact: &'static str, style: MaskingStyle) -> Term {
    Term {
        compact,
        single_word: false,
        style,
    }
}

// PLAN-MASKING 8.3, in table order: a tie between two terms covering as many words goes to the earlier one. The
// table's "e-mail" and "api key" split into the words of "email" and "apikey".
const NAME_TERMS: [Term; 49] = {
    use MaskingStyle::{Email, Full, Hash, LastFour};
    [
        term("email", Email),
        Term {
            compact: "mail",
            single_word: true,
            style: Email,
        },
        term("phone", LastFour),
        term("mobile", LastFour),
        term("tel", LastFour),
        term("telephone", LastFour),
        term("fax", LastFour),
        term("msisdn", LastFour),
        term("password", Full),
        term("passwd", Full),
        term("pwd", Full),
        term("secret", Full),
        term("token", Full),
        term("apikey", Full),
        term("accesskey", Full),
        term("privatekey", Full),
        term("credential", Full),
        term("ssn", LastFour),
        term("socialsecurity", LastFour),
        term("nationalid", LastFour),
        term("passport", LastFour),
        term("taxid", LastFour),
        term("tin", LastFour),
        term("creditcard", LastFour),
        term("cardnumber", LastFour),
        term("ccnumber", LastFour),
        term("pan", LastFour),
        term("iban", LastFour),
        term("accountnumber", LastFour),
        term("routingnumber", LastFour),
        term("address", Full),
        term("street", Full),
        term("zip", Full),
        term("zipcode", Full),
        term("postcode", Full),
        term("postal", Full),
        term("dob", Full),
        term("birthdate", Full),
        term("dateofbirth", Full),
        term("birthday", Full),
        term("ip", Hash),
        term("ipaddress", Hash),
        term("ipv4", Hash),
        term("ipv6", Hash),
        term("firstname", Full),
        term("lastname", Full),
        term("fullname", Full),
        term("surname", Full),
        term("givenname", Full),
    ]
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NameHit {
    // The term as its words join, such as "apikey" for `stripe_api_key`.
    pub term: &'static str,
    pub style: MaskingStyle,
}

// The term a column's name holds, as whole words: the one covering the most words, a tie going to table order.
pub fn column_name_hit(name: &str) -> Option<NameHit> {
    longest_term(&name_words(name), &NAME_TERMS).map(|term| NameHit {
        term: term.compact,
        style: term.style,
    })
}

// Split at `_`, `-`, `.` and a space, where a lower-case letter meets an upper-case one, and where a letter meets an
// ASCII digit either way; each word lower-cased.
pub fn name_words(name: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut previous: Option<char> = None;
    for character in name.chars() {
        if matches!(character, '_' | '-' | '.' | ' ') {
            push_word(&mut words, &mut word);
            previous = None;
            continue;
        }
        if let Some(previous) = previous {
            let case_break = previous.is_lowercase() && character.is_uppercase();
            let digit_break = (previous.is_alphabetic() && character.is_ascii_digit())
                || (previous.is_ascii_digit() && character.is_alphabetic());
            if case_break || digit_break {
                push_word(&mut words, &mut word);
            }
        }
        word.push(character);
        previous = Some(character);
    }
    push_word(&mut words, &mut word);
    words
}

fn push_word(words: &mut Vec<String>, word: &mut String) {
    if !word.is_empty() {
        words.push(std::mem::take(word).to_lowercase());
    }
}

// A term equals one word or several consecutive words joined; never part of a word.
pub(crate) fn longest_term<'t>(words: &[String], terms: &'t [Term]) -> Option<&'t Term> {
    let longest = terms.iter().map(|term| term.compact.len()).max().unwrap_or(0);
    let mut best: Option<(usize, usize)> = None;
    for start in 0..words.len() {
        let mut joined = String::new();
        for (span, word) in words[start..].iter().enumerate() {
            joined.push_str(word);
            if joined.len() > longest {
                break;
            }
            let covered = span + 1;
            let found = terms
                .iter()
                .position(|term| term.compact == joined && (!term.single_word || covered == 1));
            if let Some(order) = found
                && best.is_none_or(|(most, first)| covered > most || (covered == most && order < first))
            {
                best = Some((covered, order));
            }
        }
    }
    best.and_then(|(_, order)| terms.get(order))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit(name: &str) -> Option<(&'static str, MaskingStyle)> {
        column_name_hit(name).map(|hit| (hit.term, hit.style))
    }

    #[test]
    fn names_split_at_separators_case_changes_and_digits() {
        assert_eq!(name_words("stripe_api_key"), ["stripe", "api", "key"]);
        assert_eq!(name_words("userFirstName"), ["user", "first", "name"]);
        assert_eq!(name_words("ipv4"), ["ipv", "4"]);
        assert_eq!(name_words("Address2Line"), ["address", "2", "line"]);
        assert_eq!(name_words("API-KEY"), ["api", "key"]);
        assert_eq!(name_words("IPAddress"), ["ipaddress"]);
        assert_eq!(name_words("e.mail  x"), ["e", "mail", "x"]);
        assert_eq!(name_words("e#mail"), ["e#mail"]);
        assert!(name_words("__").is_empty());
    }

    #[test]
    fn a_term_matches_whole_words_only() {
        assert_eq!(hit("stripe_api_key"), Some(("apikey", MaskingStyle::Full)));
        assert_eq!(hit("user_first_name"), Some(("firstname", MaskingStyle::Full)));
        assert_eq!(hit("ipv4"), Some(("ipv4", MaskingStyle::Hash)));
        assert_eq!(hit("zipcode"), Some(("zipcode", MaskingStyle::Full)));
        assert_eq!(hit("classname"), None);
        assert_eq!(hit("company"), None);
        assert_eq!(hit("hotel"), None);
        assert_eq!(hit("passwords"), None);
    }

    #[test]
    fn mail_matches_only_as_one_word() {
        assert_eq!(hit("mail"), Some(("mail", MaskingStyle::Email)));
        assert_eq!(hit("work_mail"), Some(("mail", MaskingStyle::Email)));
        assert_eq!(hit("ma_il"), None);
        assert_eq!(hit("e_mail"), Some(("email", MaskingStyle::Email)));
        assert_eq!(hit("E-Mail"), Some(("email", MaskingStyle::Email)));
    }

    #[test]
    fn the_term_covering_the_most_words_wins_and_a_tie_goes_to_table_order() {
        assert_eq!(hit("ip_address"), Some(("ipaddress", MaskingStyle::Hash)));
        assert_eq!(hit("email_address"), Some(("email", MaskingStyle::Email)));
        assert_eq!(hit("home_phone_address"), Some(("phone", MaskingStyle::LastFour)));
        assert_eq!(hit("date_of_birth"), Some(("dateofbirth", MaskingStyle::Full)));
        assert_eq!(hit("customerSSN"), Some(("ssn", MaskingStyle::LastFour)));
    }
}
